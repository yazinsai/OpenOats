use crate::audio::{AudioStream, MicCaptureService};
use async_trait::async_trait;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, Stream};
use futures::stream;
use rubato::{
    Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tokio::sync::mpsc;

const TARGET_RATE: u32 = 16_000;
const CHUNK_SIZE: usize = 480;

pub struct CpalMicCapture {
    finished: Arc<AtomicBool>,
    audio_level: Arc<Mutex<f32>>,
    // Stream is !Send; we hold it behind a Mutex and declare Send manually.
    _stream: Mutex<Option<Stream>>,
}

// Safety: CpalMicCapture is only ever accessed from a single tokio task context.
// The Stream is created and held on the same thread via the Mutex guard.
unsafe impl Send for CpalMicCapture {}
unsafe impl Sync for CpalMicCapture {}

impl CpalMicCapture {
    pub fn new() -> Self {
        Self {
            finished: Arc::new(AtomicBool::new(false)),
            audio_level: Arc::new(Mutex::new(0.0)),
            _stream: Mutex::new(None),
        }
    }

    /// Returns names of all available input devices.
    pub fn available_device_names() -> Vec<String> {
        let host = cpal::default_host();
        host.input_devices()
            .map(|devs| devs.filter_map(|d| d.name().ok()).collect())
            .unwrap_or_default()
    }

    /// Returns the name of the default input device, if any.
    pub fn default_device_name() -> Option<String> {
        cpal::default_host().default_input_device()?.name().ok()
    }
}

impl Default for CpalMicCapture {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl MicCaptureService for CpalMicCapture {
    fn audio_level(&self) -> f32 {
        *self.audio_level.lock().unwrap()
    }

    fn buffer_stream_for_device(&self, device_name: Option<&str>) -> AudioStream {
        let host = cpal::default_host();

        let device = if let Some(name) = device_name {
            host.input_devices()
                .ok()
                .and_then(|mut devs| devs.find(|d| d.name().ok().as_deref() == Some(name)))
                .or_else(|| host.default_input_device())
        } else {
            host.default_input_device()
        };

        let Some(device) = device else {
            log::error!("No input device available");
            return Box::pin(stream::empty());
        };

        let (tx, rx) = mpsc::channel::<Vec<f32>>(500);
        let finished = self.finished.clone();
        let level_arc = self.audio_level.clone();

        let Ok(config) = device.default_input_config() else {
            return Box::pin(stream::empty());
        };

        let sample_rate = config.sample_rate().0;
        let channels = config.channels() as usize;
        let needs_resample = sample_rate != TARGET_RATE;

        let mut resampler = if needs_resample {
            let sinc_params = SincInterpolationParameters {
                sinc_len: 64,
                f_cutoff: 0.95,
                interpolation: SincInterpolationType::Linear,
                oversampling_factor: 64,
                window: WindowFunction::BlackmanHarris2,
            };
            SincFixedIn::<f32>::new(
                TARGET_RATE as f64 / sample_rate as f64,
                1.0,
                sinc_params,
                CHUNK_SIZE,
                1,
            )
            .ok()
        } else {
            None
        };

        let mut ring: Vec<f32> = Vec::new();
        let err_fn = |err| log::error!("Audio stream error: {}", err);
        let tx_clone = tx.clone();

        let mut process = move |mono: Vec<f32>| {
            let rms = (mono.iter().map(|s| s * s).sum::<f32>() / mono.len() as f32).sqrt();
            *level_arc.lock().unwrap() = rms;

            if finished.load(Ordering::Relaxed) {
                return;
            }

            if let Some(ref mut resampler) = resampler {
                ring.extend_from_slice(&mono);
                while ring.len() >= CHUNK_SIZE {
                    let chunk: Vec<f32> = ring.drain(..CHUNK_SIZE).collect();
                    if let Ok(out) = resampler.process(&[chunk], None) {
                        if let Some(ch) = out.into_iter().next() {
                            if !ch.is_empty() {
                                tx_clone.try_send(ch).ok();
                            }
                        }
                    }
                }
            } else {
                tx_clone.try_send(mono).ok();
            }
        };

        let stream_result = match config.sample_format() {
            SampleFormat::F32 => device.build_input_stream(
                &config.into(),
                move |data: &[f32], _: &_| {
                    let mono: Vec<f32> = data
                        .chunks(channels)
                        .map(|c| c.iter().sum::<f32>() / c.len() as f32)
                        .collect();
                    process(mono);
                },
                err_fn,
                None,
            ),
            SampleFormat::I16 => {
                let mut process2 = process;
                device.build_input_stream(
                    &config.into(),
                    move |data: &[i16], _: &_| {
                        let mono: Vec<f32> = data
                            .chunks(channels)
                            .map(|c| {
                                c.iter().map(|&s| s as f32 / 32768.0).sum::<f32>() / c.len() as f32
                            })
                            .collect();
                        process2(mono);
                    },
                    err_fn,
                    None,
                )
            }
            SampleFormat::U16 => {
                let mut process3 = process;
                device.build_input_stream(
                    &config.into(),
                    move |data: &[u16], _: &_| {
                        let mono: Vec<f32> = data
                            .chunks(channels)
                            .map(|c| {
                                c.iter()
                                    .map(|&s| (s as f32 - 32768.0) / 32768.0)
                                    .sum::<f32>()
                                    / c.len() as f32
                            })
                            .collect();
                        process3(mono);
                    },
                    err_fn,
                    None,
                )
            }
            fmt => {
                log::error!("Unsupported sample format: {:?}", fmt);
                return Box::pin(stream::empty());
            }
        };

        match stream_result {
            Ok(s) => {
                if let Err(e) = s.play() {
                    log::error!("Failed to start mic stream: {e}");
                    return Box::pin(stream::empty());
                }
                // Keep stream alive by leaking — stop() sets finished flag to drain channel.
                std::mem::forget(s);
            }
            Err(e) => {
                log::error!("Failed to build mic stream: {e}");
                return Box::pin(stream::empty());
            }
        }

        Box::pin(tokio_stream::wrappers::ReceiverStream::new(rx))
    }

    async fn is_authorized(&self) -> bool {
        true
    }

    fn finish_stream(&self) {
        self.finished.store(true, Ordering::Relaxed);
    }

    async fn stop(&self) {
        self.finish_stream();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_available_devices() {
        let devices = CpalMicCapture::available_device_names();
        println!("Available mic devices: {:?}", devices);
    }

    #[test]
    fn default_device_name_is_some_or_none() {
        let name = CpalMicCapture::default_device_name();
        println!("Default device: {:?}", name);
    }
}
