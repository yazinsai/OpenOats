/// Energy-based Voice Activity Detector.
/// Parameters (unified from Swift/Rust divergence):
///   RMS threshold: 0.005
///   Chunk size:    1600 samples (100 ms at 16 kHz)
///   Silence end:   5 consecutive silent chunks (500 ms)
pub struct Vad {
    pub rms_threshold: f32,
}

impl Vad {
    pub const CHUNK_SIZE: usize = 1_600;
    pub const SILENCE_END_CHUNKS: usize = 5;
    pub const MIN_SPEECH_SAMPLES: usize = 8_000;
    pub const FLUSH_SAMPLES: usize = 48_000;

    pub fn new() -> Self {
        Self {
            rms_threshold: 0.005,
        }
    }

    /// Returns true if the chunk contains speech above the RMS threshold.
    pub fn process_chunk(&mut self, chunk: &[f32]) -> bool {
        let rms = (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len() as f32).sqrt();
        rms > self.rms_threshold
    }
}

impl Default for Vad {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_is_not_speech() {
        let mut vad = Vad::new();
        let silence = vec![0.0f32; 1600];
        assert!(!vad.process_chunk(&silence));
    }

    #[test]
    fn loud_signal_is_speech() {
        let mut vad = Vad::new();
        let loud: Vec<f32> = (0..1600).map(|i| (i as f32 * 0.1).sin() * 0.5).collect();
        assert!(vad.process_chunk(&loud));
    }

    #[test]
    fn rms_below_threshold_is_silence() {
        let mut vad = Vad::new();
        let quiet: Vec<f32> = vec![0.001; 1600];
        assert!(!vad.process_chunk(&quiet));
    }
}
