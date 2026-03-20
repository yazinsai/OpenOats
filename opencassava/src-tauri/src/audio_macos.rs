//! macOS system audio capture via ScreenCaptureKit (macOS 13+).
//!
//! Requires "Screen Recording" permission granted in
//! System Settings → Privacy & Security → Screen Recording.
//!
//! On non-macOS builds the module compiles to a no-op stub so the
//! Windows build is not affected.

use async_trait::async_trait;
use opencassava_core::audio::{AudioCaptureService, AudioStream};
use std::error::Error;

// ── macOS implementation ──────────────────────────────────────────────────────

#[cfg(target_os = "macos")]
mod macos_impl {
    use super::*;
    use screencapturekit::{
        sc_content_filter::{InitParams, SCContentFilter},
        sc_shareable_content::SCShareableContent,
        sc_stream::SCStream,
        sc_stream_configuration::SCStreamConfiguration,
        sc_stream_handler::SCStreamOutputHandler,
        sc_stream_output_type::SCStreamOutputType,
    };
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    };
    use tokio::sync::mpsc;

    const TARGET_RATE: f64 = 16_000.0;
    const TARGET_CHANNELS: u32 = 1;

    // ── Audio buffer extraction ───────────────────────────────────────────────

    /// Extract f32 mono samples from a ScreenCaptureKit CMSampleBuffer.
    ///
    /// SCKit delivers Float32 PCM at the configured sample rate. We call
    /// the CoreMedia C function to get the raw AudioBufferList, then
    /// downmix to mono if needed.
    fn extract_samples(
        buffer: &screencapturekit::cm_sample_buffer::CMSampleBuffer,
        channels: u32,
    ) -> Vec<f32> {
        use coreaudio_sys::{
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, AudioBufferList,
            CMBlockBufferRef, CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer,
            CMSampleBufferRef,
        };

        unsafe {
            let sample_buf_ref: CMSampleBufferRef = buffer.as_concrete_TypeRef();

            // Allocate storage for AudioBufferList with `channels` buffers.
            // The struct has one embedded AudioBuffer; extra buffers follow.
            let extra = channels.saturating_sub(1) as usize;
            let buf_size = std::mem::size_of::<AudioBufferList>()
                + extra * std::mem::size_of::<coreaudio_sys::AudioBuffer>();

            let mut storage = vec![0u8; buf_size];
            let abl = storage.as_mut_ptr() as *mut AudioBufferList;
            let mut block_buf: CMBlockBufferRef = std::ptr::null_mut();

            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample_buf_ref,
                std::ptr::null_mut(),
                abl,
                buf_size,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                &mut block_buf,
            );

            if status != 0 || block_buf.is_null() {
                return vec![];
            }

            // Collect interleaved f32 samples from all buffers.
            let n_bufs = (*abl).mNumberBuffers as usize;
            let mut interleaved: Vec<f32> = Vec::new();
            for i in 0..n_bufs {
                let ab = &(*abl).mBuffers[i];
                let n = ab.mDataByteSize as usize / std::mem::size_of::<f32>();
                let slice = std::slice::from_raw_parts(ab.mData as *const f32, n);
                interleaved.extend_from_slice(slice);
            }

            // Release the retained block buffer.
            coreaudio_sys::CFRelease(block_buf as *const _);

            // Downmix to mono.
            if channels > 1 {
                interleaved = interleaved
                    .chunks(channels as usize)
                    .map(|c| c.iter().sum::<f32>() / channels as f32)
                    .collect();
            }

            interleaved
        }
    }

    // ── SCStreamOutputHandler ─────────────────────────────────────────────────

    struct AudioSampleHandler {
        tx: mpsc::Sender<Vec<f32>>,
        finished: Arc<AtomicBool>,
        level: Arc<Mutex<f32>>,
        channels: u32,
    }

    impl SCStreamOutputHandler for AudioSampleHandler {
        fn did_output_sample_buffer(
            &self,
            buffer: screencapturekit::cm_sample_buffer::CMSampleBuffer,
            of_type: SCStreamOutputType,
        ) {
            if of_type != SCStreamOutputType::Audio {
                return;
            }
            if self.finished.load(Ordering::Relaxed) {
                return;
            }

            let samples = extract_samples(&buffer, self.channels);
            if samples.is_empty() {
                return;
            }

            let rms = (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt();
            *self.level.lock().unwrap() = rms;

            self.tx.blocking_send(samples).ok();
        }
    }

    // ── Public capture struct ─────────────────────────────────────────────────

    pub struct MacosAudioCapture {
        finished: Arc<AtomicBool>,
        level: Arc<Mutex<f32>>,
    }

    // SCStream holds Objective-C objects which are Send in practice here.
    unsafe impl Send for MacosAudioCapture {}
    unsafe impl Sync for MacosAudioCapture {}

    impl MacosAudioCapture {
        pub fn new() -> Self {
            Self {
                finished: Arc::new(AtomicBool::new(false)),
                level: Arc::new(Mutex::new(0.0)),
            }
        }
    }

    #[async_trait]
    impl AudioCaptureService for MacosAudioCapture {
        fn audio_level(&self) -> f32 {
            *self.level.lock().unwrap()
        }

        async fn buffer_stream(&self) -> Result<AudioStream, Box<dyn Error + Send + Sync>> {
            // SCShareableContent::get() checks screen-recording permission.
            let content = tokio::task::spawn_blocking(SCShareableContent::get)
                .await
                .map_err(|e| format!("join error: {e}"))?
                .map_err(|e| format!("SCShareableContent: {:?}", e))?;

            let display = content
                .displays()
                .into_iter()
                .next()
                .ok_or("No display found for ScreenCaptureKit audio")?;

            let filter = SCContentFilter::new(InitParams::Display(display));

            let config = SCStreamConfiguration::new();
            config.set_captures_audio(true);
            config.set_sample_rate(TARGET_RATE);
            config.set_channel_count(TARGET_CHANNELS);
            // ScreenCaptureKit requires non-zero video dimensions even for audio-only.
            config.set_width(2);
            config.set_height(2);

            let (tx, rx) = mpsc::channel::<Vec<f32>>(200);

            let handler = AudioSampleHandler {
                tx,
                finished: self.finished.clone(),
                level: self.level.clone(),
                channels: TARGET_CHANNELS,
            };

            let stream = SCStream::new(filter, config, handler);
            stream.add_output(SCStreamOutputType::Audio);
            stream
                .start_capture()
                .map_err(|e| format!("SCStream start_capture: {:?}", e))?;

            // Leak the stream to keep the capture running.
            // finish_stream() sets the finished flag; the handler stops sending.
            std::mem::forget(stream);

            Ok(Box::pin(tokio_stream::wrappers::ReceiverStream::new(rx)))
        }

        fn finish_stream(&self) {
            self.finished.store(true, Ordering::Relaxed);
        }

        async fn stop(&self) {
            self.finish_stream();
        }
    }
}

// ── Non-macOS stub ────────────────────────────────────────────────────────────

#[cfg(not(target_os = "macos"))]
mod macos_impl {
    use super::*;
    use futures::stream;

    pub struct MacosAudioCapture;

    impl MacosAudioCapture {
        pub fn new() -> Self {
            Self
        }
    }

    #[async_trait]
    impl AudioCaptureService for MacosAudioCapture {
        fn audio_level(&self) -> f32 {
            0.0
        }
        async fn buffer_stream(&self) -> Result<AudioStream, Box<dyn Error + Send + Sync>> {
            Ok(Box::pin(stream::empty()))
        }
        fn finish_stream(&self) {}
        async fn stop(&self) {}
    }
}

pub use macos_impl::MacosAudioCapture;
