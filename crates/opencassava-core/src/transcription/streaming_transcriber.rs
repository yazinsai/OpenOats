use crate::transcription::vad::Vad;
use futures::Stream;
use std::sync::mpsc;
use std::thread;

pub type OnFinal = Box<dyn Fn(String) + Send + 'static>;
pub type OnVolatile = Box<dyn Fn(String) + Send + 'static>;

pub struct StreamingTranscriber {
    on_final: OnFinal,
    /// Optional: path to whisper model. If None, transcriber runs in passthrough mode (VAD only).
    model_path: Option<String>,
    language: String,
    on_volatile: Option<OnVolatile>,
}

impl StreamingTranscriber {
    pub fn new(model_path: String, language: String, on_final: OnFinal) -> Self {
        Self {
            on_final,
            model_path: Some(model_path),
            language,
            on_volatile: None,
        }
    }

    /// Test-only: passthrough mode that skips actual transcription.
    pub fn new_passthrough(on_final: OnFinal) -> Self {
        Self {
            on_final,
            model_path: None,
            language: "en".into(),
            on_volatile: None,
        }
    }

    /// Builder: attach a volatile (in-progress) speech callback.
    pub fn with_volatile(mut self, on_volatile: OnVolatile) -> Self {
        self.on_volatile = Some(on_volatile);
        self
    }

    pub async fn run<S>(self, stream: S)
    where
        S: Stream<Item = Vec<f32>> + Send + 'static,
    {
        use futures::StreamExt;

        let (seg_tx, seg_rx) = mpsc::sync_channel::<Vec<f32>>(10);
        let on_final = self.on_final;
        let on_volatile = self.on_volatile;
        let language = self.language.clone();
        let model_path = self.model_path.clone();

        let transcribe_thread = thread::spawn(move || {
            if let Some(path) = model_path {
                match crate::transcription::whisper::WhisperManager::new(&path, &language) {
                    Ok(manager) => {
                        let mut state = match manager.create_state() {
                            Ok(s) => s,
                            Err(e) => {
                                log::error!("whisper state: {e}");
                                return;
                            }
                        };
                        for samples in seg_rx.iter() {
                            let text = crate::transcription::whisper::WhisperManager::transcribe(
                                &mut state, &samples, &language,
                            );
                            if !text.is_empty() {
                                log::info!("[transcriber] {}", &text[..text.len().min(80)]);
                                on_final(text);
                            }
                        }
                    }
                    Err(e) => log::error!("Failed to load whisper model: {e}"),
                }
            }
            // passthrough mode: drain and discard
            for _ in seg_rx.iter() {}
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
                            let _ = seg_tx.send(std::mem::take(&mut speech_buf));
                        } else {
                            speech_buf.clear();
                        }
                    }
                }

                if speaking && speech_buf.len() >= Vad::FLUSH_SAMPLES {
                    let _ = seg_tx.send(std::mem::take(&mut speech_buf));
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
            let _ = seg_tx.send(speech_buf);
        }

        drop(seg_tx);
        let _ = transcribe_thread.join();
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
