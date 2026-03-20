use crate::transcription::vad::Vad;
use futures::Stream;
use std::sync::{
    atomic::AtomicBool,
    Arc,
};
use std::sync::mpsc;

pub type OnFinal = Box<dyn Fn(String) + Send + 'static>;
pub type OnVolatile = Box<dyn Fn(String) + Send + 'static>;
pub type OnProgress = Arc<dyn Fn(SegmentProgress) + Send + Sync + 'static>;

#[derive(Clone, Copy)]
pub enum SegmentProgress {
    Captured,
    Processed,
}

#[derive(Clone)]
pub enum SttBackend {
    WhisperRs { model_path: String },
    FasterWhisper(crate::transcription::faster_whisper::FasterWhisperConfig),
    Passthrough,
}

pub struct StreamingTranscriber {
    on_final: OnFinal,
    backend: SttBackend,
    language: String,
    on_volatile: Option<OnVolatile>,
    on_progress: Option<OnProgress>,
    stop_signal: Option<Arc<AtomicBool>>,
}

impl StreamingTranscriber {
    pub fn new(backend: SttBackend, language: String, on_final: OnFinal) -> Self {
        Self {
            on_final,
            backend,
            language,
            on_volatile: None,
            on_progress: None,
            stop_signal: None,
        }
    }

    /// Test-only: passthrough mode that skips actual transcription.
    pub fn new_passthrough(on_final: OnFinal) -> Self {
        Self {
            on_final,
            backend: SttBackend::Passthrough,
            language: "en".into(),
            on_volatile: None,
            on_progress: None,
            stop_signal: None,
        }
    }

    /// Builder: attach a volatile (in-progress) speech callback.
    pub fn with_volatile(mut self, on_volatile: OnVolatile) -> Self {
        self.on_volatile = Some(on_volatile);
        self
    }

    pub fn with_progress(mut self, on_progress: OnProgress) -> Self {
        self.on_progress = Some(on_progress);
        self
    }

    pub fn with_stop_signal(mut self, stop_signal: Arc<AtomicBool>) -> Self {
        self.stop_signal = Some(stop_signal);
        self
    }

    pub async fn run<S>(self, stream: S)
    where
        S: Stream<Item = Vec<f32>> + Send + 'static,
    {
        use futures::StreamExt;

        let (seg_tx, seg_rx) = mpsc::sync_channel::<Vec<f32>>(30);
        let on_final = self.on_final;
        let on_volatile = self.on_volatile;
        let on_progress = self.on_progress;
        let progress_for_backend = on_progress.clone();
        let language = self.language.clone();
        let backend = self.backend.clone();

        // Run Whisper on a blocking thread-pool thread so that joining it is
        // async-friendly. Using std::thread::join() inside an async fn would
        // block a tokio worker, causing handle.await in stop_transcription to
        // return before the drain completes and letting is_running flip to
        // false while segments are still being transcribed.
        let whisper_task = tokio::task::spawn_blocking(move || {
            match backend {
                SttBackend::WhisperRs { model_path } => {
                    match crate::transcription::whisper::WhisperManager::new(&model_path, &language)
                    {
                        Ok(manager) => {
                            let mut state = match manager.create_state() {
                                Ok(s) => s,
                                Err(e) => {
                                    log::error!("whisper state: {e}");
                                    return;
                                }
                            };
                            for samples in seg_rx.iter() {
                                let text =
                                    crate::transcription::whisper::WhisperManager::transcribe(
                                        &mut state, &samples, &language,
                                    );
                                if let Some(ref on_progress) = progress_for_backend {
                                    on_progress(SegmentProgress::Processed);
                                }
                                if !text.is_empty() {
                                    log::info!("[transcriber] {}", &text[..text.len().min(80)]);
                                    on_final(text);
                                }
                            }
                        }
                        Err(e) => log::error!("Failed to load whisper model: {e}"),
                    }
                }
                SttBackend::FasterWhisper(config) => {
                    match crate::transcription::faster_whisper::FasterWhisperWorker::spawn(&config) {
                        Ok(mut worker) => {
                            for samples in seg_rx.iter() {
                                match worker.transcribe(&samples, &language) {
                                    Ok(text) if !text.is_empty() => {
                                        if let Some(ref on_progress) = progress_for_backend {
                                            on_progress(SegmentProgress::Processed);
                                        }
                                        log::info!("[transcriber] {}", &text[..text.len().min(80)]);
                                        on_final(text);
                                    }
                                    Ok(_) => {
                                        if let Some(ref on_progress) = progress_for_backend {
                                            on_progress(SegmentProgress::Processed);
                                        }
                                    }
                                    Err(e) => log::error!("faster-whisper transcribe error: {e}"),
                                }
                            }
                        }
                        Err(e) => log::error!("Failed to launch faster-whisper worker: {e}"),
                    }
                }
                SttBackend::Passthrough => {
                    for _ in seg_rx.iter() {}
                }
            }
        });

        let mut vad = Vad::new();
        let mut vad_buf: Vec<f32> = Vec::new();
        let mut speech_buf: Vec<f32> = Vec::new();
        let mut speaking = false;
        let mut silence_count = 0usize;
        let mut last_volatile_at = std::time::Instant::now();
        let volatile_interval = std::time::Duration::from_millis(500);
        // Fallback: count samples processed while speaking to fire volatile
        // even when wall-clock elapsed is near-zero (e.g. in fast tests).
        let volatile_sample_interval: usize = 8_000; // 500 ms at 16 kHz
        let mut speaking_samples_since_volatile: usize = 0;

        let mut stream = Box::pin(stream);
        // Stop is signalled by the upstream sender being dropped (mic capture
        // sets tx_opt=None when stop_requested fires), which causes
        // stream.next() to return None.  We no longer break early on the stop
        // signal; instead we let the stream drain fully so every captured
        // chunk reaches VAD and Whisper before the pipeline shuts down.
        while let Some(samples) = stream.next().await {
            vad_buf.extend_from_slice(&samples);

            while vad_buf.len() >= Vad::CHUNK_SIZE {
                let chunk: Vec<f32> = vad_buf.drain(..Vad::CHUNK_SIZE).collect();
                let active = vad.process_chunk(&chunk);

                if active {
                    silence_count = 0;
                    speaking = true;
                    speech_buf.extend_from_slice(&chunk);
                } else if speaking {
                    silence_count += 1;
                    speech_buf.extend_from_slice(&chunk);

                    if silence_count >= Vad::SILENCE_END_CHUNKS {
                        speaking = false;
                        silence_count = 0;
                        if speech_buf.len() > Vad::MIN_SPEECH_SAMPLES {
                            match seg_tx.try_send(std::mem::take(&mut speech_buf)) {
                                Ok(_) => {
                                    if let Some(ref on_progress) = on_progress {
                                        on_progress(SegmentProgress::Captured);
                                    }
                                }
                                Err(e) => { log::warn!("[vad] seg dropped (end-of-speech): {e}"); }
                            }
                        } else {
                            speech_buf.clear();
                        }
                    }
                }

                if speaking && speech_buf.len() >= Vad::FLUSH_SAMPLES {
                    match seg_tx.try_send(std::mem::take(&mut speech_buf)) {
                        Ok(_) => {
                            if let Some(ref on_progress) = on_progress {
                                on_progress(SegmentProgress::Captured);
                            }
                        }
                        Err(e) => { log::warn!("[vad] seg dropped (flush): {e}"); }
                    }
                }

                // Emit volatile text while speech is active
                if speaking {
                    speaking_samples_since_volatile += Vad::CHUNK_SIZE;
                    if let Some(ref on_vol) = on_volatile {
                        let time_elapsed = last_volatile_at.elapsed() >= volatile_interval;
                        let samples_elapsed =
                            speaking_samples_since_volatile >= volatile_sample_interval;
                        if time_elapsed || samples_elapsed {
                            on_vol("...".to_string());
                            last_volatile_at = std::time::Instant::now();
                            speaking_samples_since_volatile = 0;
                        }
                    }
                } else {
                    speaking_samples_since_volatile = 0;
                }
            }
        }

        // Flush remainder
        if speech_buf.len() > Vad::MIN_SPEECH_SAMPLES {
            if seg_tx.send(speech_buf).is_ok() {
                if let Some(ref on_progress) = on_progress {
                    on_progress(SegmentProgress::Captured);
                }
            }
        }

        drop(seg_tx);
        let _ = whisper_task.await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::stream;

    #[tokio::test]
    async fn silence_produces_no_transcription() {
        let (tx, rx) = std::sync::mpsc::channel();
        let on_final = move |text: String| {
            tx.send(text).ok();
        };
        let transcriber = StreamingTranscriber::new_passthrough(Box::new(on_final));
        let silence: Vec<Vec<f32>> = (0..30).map(|_| vec![0.0f32; 1600]).collect();
        transcriber.run(stream::iter(silence)).await;
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn volatile_fires_while_speaking() {
        use std::sync::{Arc, Mutex};
        let calls: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let calls_clone = Arc::clone(&calls);
        let on_final = Box::new(|_text: String| {});
        let on_volatile = Box::new(move |text: String| {
            calls_clone.lock().unwrap().push(text);
        });
        let transcriber =
            StreamingTranscriber::new_passthrough(on_final).with_volatile(on_volatile);

        // 2 seconds of continuous speech-level audio (non-silence) at 16kHz
        let speech_chunk: Vec<f32> = (0..1600).map(|i| (i as f32 / 100.0).sin() * 0.5).collect();
        let chunks: Vec<Vec<f32>> = (0..200).map(|_| speech_chunk.clone()).collect();
        transcriber.run(futures::stream::iter(chunks)).await;
        assert!(
            !calls.lock().unwrap().is_empty(),
            "volatile should have fired at least once"
        );
    }
}
