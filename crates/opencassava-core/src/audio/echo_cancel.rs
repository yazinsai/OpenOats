use num_complex::Complex32;
use realfft::{ComplexToReal, RealFftPlanner, RealToComplex};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

const SAMPLE_RATE: usize = 16_000;
const DEFAULT_REFERENCE_WINDOW_MS: usize = 1_000;
const MIN_RENDER_RMS: f32 = 0.008;

const BLOCK_SIZE: usize = 256;
const FFT_SIZE: usize = 512;
const NUM_PARTITIONS: usize = 16;
const SPEC_SIZE: usize = FFT_SIZE / 2 + 1;
const MU: f32 = 0.5;
const POWER_SMOOTH: f32 = 0.8;
const REGULARIZATION: f32 = 1e-6;
const SILENCE_DECAY_BLOCKS: usize = 50;

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let mean_sq = samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32;
    mean_sq.sqrt()
}

#[derive(Clone)]
pub struct EchoReferenceBuffer {
    inner: Arc<Mutex<VecDeque<f32>>>,
    capacity: usize,
    total_pushed: Arc<AtomicUsize>,
}

impl EchoReferenceBuffer {
    pub fn new(window_ms: usize) -> Self {
        let capacity = SAMPLE_RATE * window_ms / 1_000;
        Self {
            inner: Arc::new(Mutex::new(VecDeque::with_capacity(capacity))),
            capacity: capacity.max(SAMPLE_RATE / 2),
            total_pushed: Arc::new(AtomicUsize::new(0)),
        }
    }

    pub fn default_window() -> Self {
        Self::new(DEFAULT_REFERENCE_WINDOW_MS)
    }

    pub fn push_render_chunk(&self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        let mut inner = self.inner.lock().unwrap();
        for &sample in samples {
            if inner.len() == self.capacity {
                inner.pop_front();
            }
            inner.push_back(sample);
        }
        self.total_pushed
            .fetch_add(samples.len(), Ordering::Relaxed);
    }

    fn total_pushed(&self) -> usize {
        self.total_pushed.load(Ordering::Relaxed)
    }

    fn read_block_at(&self, abs_offset: usize) -> Option<Vec<f32>> {
        let inner = self.inner.lock().unwrap();
        let total = self.total_pushed();
        let evicted = total.saturating_sub(inner.len());
        if abs_offset < evicted || abs_offset + BLOCK_SIZE > total {
            return None;
        }
        let local_start = abs_offset - evicted;
        Some(
            inner
                .iter()
                .skip(local_start)
                .take(BLOCK_SIZE)
                .copied()
                .collect(),
        )
    }
}

impl Default for EchoReferenceBuffer {
    fn default() -> Self {
        Self::default_window()
    }
}

struct FreqDomainAec {
    filter: Vec<Vec<Complex32>>,
    ref_spectra: VecDeque<Vec<Complex32>>,
    ref_power: Vec<f32>,
    prev_mic_block: Vec<f32>,
    prev_ref_block: Vec<f32>,
    fft_forward: Arc<dyn RealToComplex<f32>>,
    fft_inverse: Arc<dyn ComplexToReal<f32>>,
    silence_blocks: usize,
}

impl FreqDomainAec {
    fn new() -> Self {
        let mut planner = RealFftPlanner::<f32>::new();
        let fft_forward = planner.plan_fft_forward(FFT_SIZE);
        let fft_inverse = planner.plan_fft_inverse(FFT_SIZE);
        let zero_spec = vec![Complex32::new(0.0, 0.0); SPEC_SIZE];

        Self {
            filter: (0..NUM_PARTITIONS).map(|_| zero_spec.clone()).collect(),
            ref_spectra: VecDeque::with_capacity(NUM_PARTITIONS),
            ref_power: vec![1e-4; SPEC_SIZE],
            prev_mic_block: vec![0.0; BLOCK_SIZE],
            prev_ref_block: vec![0.0; BLOCK_SIZE],
            fft_forward,
            fft_inverse,
            silence_blocks: 0,
        }
    }

    fn process_block(&mut self, mic_block: &[f32], ref_block: &[f32]) -> Vec<f32> {
        debug_assert_eq!(mic_block.len(), BLOCK_SIZE);
        debug_assert_eq!(ref_block.len(), BLOCK_SIZE);

        let ref_rms = rms(ref_block);
        if ref_rms < MIN_RENDER_RMS {
            self.silence_blocks += 1;
            if self.silence_blocks > SILENCE_DECAY_BLOCKS {
                for partition in &mut self.filter {
                    for coeff in partition.iter_mut() {
                        *coeff *= 0.9;
                    }
                }
            }
            self.prev_mic_block.copy_from_slice(mic_block);
            self.prev_ref_block.copy_from_slice(ref_block);
            return mic_block.to_vec();
        }
        self.silence_blocks = 0;

        let mic_spec = self.forward_fft_overlap_save(mic_block, &self.prev_mic_block.clone());
        let ref_spec = self.forward_fft_overlap_save(ref_block, &self.prev_ref_block.clone());

        self.ref_spectra.push_front(ref_spec.clone());
        if self.ref_spectra.len() > NUM_PARTITIONS {
            self.ref_spectra.pop_back();
        }

        // Compute total reference power across all partitions for normalization
        let mut total_ref_power = vec![REGULARIZATION; SPEC_SIZE];
        for p in 0..self.ref_spectra.len().min(NUM_PARTITIONS) {
            for k in 0..SPEC_SIZE {
                total_ref_power[k] += self.ref_spectra[p][k].norm_sqr();
            }
        }
        // Smooth power estimate
        for k in 0..SPEC_SIZE {
            self.ref_power[k] =
                POWER_SMOOTH * self.ref_power[k] + (1.0 - POWER_SMOOTH) * total_ref_power[k];
        }

        // Compute echo estimate: sum over partitions of W_p * X_p
        let mut echo_est = vec![Complex32::new(0.0, 0.0); SPEC_SIZE];
        let num_active = self.ref_spectra.len().min(NUM_PARTITIONS);
        for p in 0..num_active {
            let x_p = &self.ref_spectra[p];
            let w_p = &self.filter[p];
            for k in 0..SPEC_SIZE {
                echo_est[k] += w_p[k] * x_p[k];
            }
        }

        // Error = mic - echo_estimate
        let error_spec: Vec<Complex32> = mic_spec
            .iter()
            .zip(echo_est.iter())
            .map(|(&m, &e)| m - e)
            .collect();

        let output = self.inverse_fft_overlap_save(&error_spec);

        // Update filter: NLMS in frequency domain
        for p in 0..num_active {
            let x_p = &self.ref_spectra[p];
            let mut gradient = vec![Complex32::new(0.0, 0.0); SPEC_SIZE];
            for k in 0..SPEC_SIZE {
                let norm_power = self.ref_power[k];
                gradient[k] = error_spec[k] * x_p[k].conj() * (MU / norm_power);
            }

            let constrained = self.constrain_gradient(&gradient);
            for k in 0..SPEC_SIZE {
                self.filter[p][k] += constrained[k];
            }
        }

        self.prev_mic_block.copy_from_slice(mic_block);
        self.prev_ref_block.copy_from_slice(ref_block);

        output
    }

    fn forward_fft_overlap_save(&self, current: &[f32], previous: &[f32]) -> Vec<Complex32> {
        let mut frame = vec![0.0f32; FFT_SIZE];
        frame[..BLOCK_SIZE].copy_from_slice(previous);
        frame[BLOCK_SIZE..].copy_from_slice(current);
        let mut spectrum = vec![Complex32::new(0.0, 0.0); SPEC_SIZE];
        self.fft_forward.process(&mut frame, &mut spectrum).unwrap();
        spectrum
    }

    fn inverse_fft_overlap_save(&self, spectrum: &[Complex32]) -> Vec<f32> {
        let mut spec = spectrum.to_vec();
        let mut time = vec![0.0f32; FFT_SIZE];
        self.fft_inverse.process(&mut spec, &mut time).unwrap();
        let norm = 1.0 / FFT_SIZE as f32;
        time[BLOCK_SIZE..]
            .iter()
            .map(|&s| (s * norm).clamp(-1.0, 1.0))
            .collect()
    }

    fn constrain_gradient(&self, gradient: &[Complex32]) -> Vec<Complex32> {
        let mut spec = gradient.to_vec();
        let mut time = vec![0.0f32; FFT_SIZE];
        self.fft_inverse.process(&mut spec, &mut time).unwrap();
        let norm = 1.0 / FFT_SIZE as f32;
        for s in time.iter_mut() {
            *s *= norm;
        }
        for s in time[BLOCK_SIZE..].iter_mut() {
            *s = 0.0;
        }
        let mut constrained_spec = vec![Complex32::new(0.0, 0.0); SPEC_SIZE];
        self.fft_forward
            .process(&mut time, &mut constrained_spec)
            .unwrap();
        constrained_spec
    }
}

pub struct MicEchoProcessor {
    reference: EchoReferenceBuffer,
    aec: FreqDomainAec,
    enabled: bool,
    threshold: f32,
    mic_accum: Vec<f32>,
    out_accum: VecDeque<f32>,
    ref_abs_offset: usize,
}

impl MicEchoProcessor {
    pub fn new(reference: EchoReferenceBuffer) -> Self {
        let initial_offset = reference.total_pushed();
        Self {
            reference,
            aec: FreqDomainAec::new(),
            enabled: true,
            threshold: 0.0,
            mic_accum: Vec::with_capacity(BLOCK_SIZE * 2),
            out_accum: VecDeque::with_capacity(BLOCK_SIZE * 4),
            ref_abs_offset: initial_offset,
        }
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn set_threshold(&mut self, threshold: f32) {
        self.threshold = threshold;
    }

    pub fn process_chunk(&mut self, mic: &[f32]) -> Vec<f32> {
        if mic.is_empty() {
            return mic.to_vec();
        }

        let cleaned = if !self.enabled {
            mic.to_vec()
        } else {
            self.mic_accum.extend_from_slice(mic);

            while self.mic_accum.len() >= BLOCK_SIZE {
                let mic_block: Vec<f32> = self.mic_accum.drain(..BLOCK_SIZE).collect();

                let ref_block = match self.reference.read_block_at(self.ref_abs_offset) {
                    Some(block) => {
                        self.ref_abs_offset += BLOCK_SIZE;
                        block
                    }
                    None => {
                        self.out_accum.extend(mic_block.iter());
                        self.ref_abs_offset += BLOCK_SIZE;
                        continue;
                    }
                };

                let processed = self.aec.process_block(&mic_block, &ref_block);
                self.out_accum.extend(processed.iter());
            }

            let needed = mic.len();
            if self.out_accum.len() >= needed {
                self.out_accum.drain(..needed).collect()
            } else {
                let mut result: Vec<f32> = self.out_accum.drain(..).collect();
                let remaining = needed - result.len();
                result.extend_from_slice(&mic[mic.len() - remaining..]);
                result
            }
        };

        // Noise gate: applies regardless of AEC enabled state
        if self.threshold > 0.0 && rms(&cleaned) < self.threshold {
            return vec![0.0; mic.len()];
        }

        cleaned
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn energy(samples: &[f32]) -> f32 {
        samples.iter().map(|s| s * s).sum::<f32>() / samples.len().max(1) as f32
    }

    fn chunk_rms(samples: &[f32]) -> f32 {
        let sq: f32 = samples.iter().map(|s| s * s).sum();
        (sq / samples.len() as f32).sqrt()
    }

    #[test]
    fn gate_silences_chunk_below_threshold() {
        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());
        processor.set_enabled(false);
        processor.set_threshold(0.1);

        let quiet = vec![0.001f32; 480];
        reference.push_render_chunk(&quiet);
        let out = processor.process_chunk(&quiet);
        assert_eq!(out.len(), quiet.len(), "length must be preserved");
        assert!(
            chunk_rms(&out) < 1e-6,
            "output should be silence, got rms={}",
            chunk_rms(&out)
        );
    }

    #[test]
    fn gate_passes_chunk_above_threshold() {
        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());
        processor.set_enabled(false);
        processor.set_threshold(0.05);

        let loud: Vec<f32> = (0..480).map(|i| (i as f32 * 0.1).sin() * 0.5).collect();
        reference.push_render_chunk(&loud);
        let out = processor.process_chunk(&loud);
        assert!(
            chunk_rms(&out) > 0.1,
            "loud audio should pass gate, got rms={}",
            chunk_rms(&out)
        );
    }

    #[test]
    fn gate_disabled_when_threshold_zero() {
        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());
        processor.set_enabled(false);
        // default threshold is 0.0 — gate should be open
        let quiet = vec![0.001f32; 480];
        reference.push_render_chunk(&quiet);
        let out = processor.process_chunk(&quiet);
        assert!(
            chunk_rms(&out) > 0.0005,
            "gate should be open when threshold=0, got rms={}",
            chunk_rms(&out)
        );
    }

    #[test]
    fn gate_applies_when_aec_enabled() {
        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());
        processor.set_enabled(false);
        processor.set_threshold(0.2);

        // loud chunk — rms ~0.35 → above threshold, must pass
        let loud: Vec<f32> = (0..480).map(|i| (i as f32 * 0.1).sin() * 0.5).collect();
        reference.push_render_chunk(&loud);
        let out_loud = processor.process_chunk(&loud);
        assert!(
            chunk_rms(&out_loud) > 0.1,
            "loud chunk should pass gate, got rms={}",
            chunk_rms(&out_loud)
        );

        // quiet chunk — rms ~0.003 → below threshold, must be silenced
        let quiet = vec![0.005f32; 480];
        reference.push_render_chunk(&quiet);
        let out_quiet = processor.process_chunk(&quiet);
        assert!(
            chunk_rms(&out_quiet) < 1e-6,
            "quiet chunk should be silenced by gate, got rms={}",
            chunk_rms(&out_quiet)
        );
    }

    #[test]
    fn freq_domain_aec_cancels_pure_echo() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let render: Vec<f32> = (0..64_000)
            .map(|i| {
                let mut h = DefaultHasher::new();
                i.hash(&mut h);
                (h.finish() as f32 / u64::MAX as f32) * 2.0 - 1.0
            })
            .collect();

        let delay = 80;
        let mut mic = vec![0.0f32; delay];
        mic.extend(render.iter().map(|&s| s * 0.6));
        mic.truncate(render.len());

        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());

        let chunk_size = 480;
        let mut all_cleaned = Vec::new();

        for (render_chunk, mic_chunk) in render.chunks(chunk_size).zip(mic.chunks(chunk_size)) {
            reference.push_render_chunk(render_chunk);
            let cleaned = processor.process_chunk(mic_chunk);
            assert_eq!(
                cleaned.len(),
                mic_chunk.len(),
                "output length must match input"
            );
            all_cleaned.extend_from_slice(&cleaned);
        }

        let tail_start = 32_000;
        let raw_tail_energy = energy(&mic[tail_start..]);
        let cleaned_tail_energy = energy(&all_cleaned[tail_start..]);
        let ratio = cleaned_tail_energy / raw_tail_energy;
        assert!(
            ratio < 0.15,
            "cleaned energy should be < 15% of raw, got {:.2}%",
            ratio * 100.0
        );
    }

    #[test]
    fn freq_domain_aec_preserves_speech_during_doubletalk() {
        let n = 64_000;
        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());

        let render: Vec<f32> = (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * 200.0 * i as f32 / 16_000.0).sin() * 0.5)
            .collect();

        let mic: Vec<f32> = (0..n)
            .map(|i| {
                let local_speech =
                    (2.0 * std::f32::consts::PI * 800.0 * i as f32 / 16_000.0).sin() * 0.4;
                let echo = (2.0 * std::f32::consts::PI * 200.0 * i as f32 / 16_000.0).sin() * 0.3;
                local_speech + echo
            })
            .collect();

        let chunk_size = 480;
        let mut all_cleaned = Vec::new();
        for (render_chunk, mic_chunk) in render.chunks(chunk_size).zip(mic.chunks(chunk_size)) {
            reference.push_render_chunk(render_chunk);
            let cleaned = processor.process_chunk(mic_chunk);
            all_cleaned.extend_from_slice(&cleaned);
        }

        let tail_start = 32_000;
        let local_only: Vec<f32> = (tail_start..n)
            .map(|i| (2.0 * std::f32::consts::PI * 800.0 * i as f32 / 16_000.0).sin() * 0.4)
            .collect();

        let local_energy = energy(&local_only);
        let cleaned_energy = energy(&all_cleaned[tail_start..]);
        let ratio = cleaned_energy / local_energy;
        assert!(
            ratio > 0.70,
            "local speech energy should be > 70% preserved, got {:.2}%",
            ratio * 100.0
        );
    }

    #[test]
    fn freq_domain_aec_converges_within_400ms() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());

        let mut converged_at_block = None;
        let target_ratio = 10.0f32.powf(-15.0 / 10.0);

        for block_idx in 0..200 {
            let offset = block_idx * BLOCK_SIZE;
            let render: Vec<f32> = (0..BLOCK_SIZE)
                .map(|i| {
                    let mut h = DefaultHasher::new();
                    (offset + i).hash(&mut h);
                    (h.finish() as f32 / u64::MAX as f32) * 2.0 - 1.0
                })
                .collect();
            let mic: Vec<f32> = render.iter().map(|&s| s * 0.5).collect();

            reference.push_render_chunk(&render);
            let cleaned = processor.process_chunk(&mic);

            let raw_e = energy(&mic);
            let clean_e = energy(&cleaned);
            if raw_e > 0.0 && clean_e / raw_e < target_ratio && converged_at_block.is_none() {
                converged_at_block = Some(block_idx);
            }
        }

        let block = converged_at_block.expect("filter never converged to 15dB suppression");
        let ms = block * BLOCK_SIZE * 1000 / SAMPLE_RATE;
        assert!(
            block < 25,
            "should converge within 25 blocks (400ms), converged at block {} ({}ms)",
            block,
            ms
        );
    }

    #[test]
    fn freq_domain_aec_handles_variable_chunk_sizes() {
        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());

        let chunk_sizes = [100, 256, 500, 1000, 37, 480];
        let mut total_in = 0;
        let mut total_out = 0;

        for &size in &chunk_sizes {
            let render = vec![0.1f32; size];
            let mic = vec![0.05f32; size];
            reference.push_render_chunk(&render);
            let cleaned = processor.process_chunk(&mic);
            assert_eq!(
                cleaned.len(),
                size,
                "output length must match input length {}",
                size
            );
            total_in += size;
            total_out += cleaned.len();
        }
        assert_eq!(total_in, total_out);
    }

    #[test]
    fn freq_domain_aec_cancels_delayed_echo() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());

        let n = 64_000;
        let delay = 2400;

        let render: Vec<f32> = (0..n)
            .map(|i| {
                let mut h = DefaultHasher::new();
                i.hash(&mut h);
                (h.finish() as f32 / u64::MAX as f32) * 2.0 - 1.0
            })
            .collect();

        let mut mic = vec![0.0f32; delay];
        mic.extend(render.iter().map(|&s| s * 0.5));
        mic.truncate(n);

        let chunk_size = 480;
        let mut all_cleaned = Vec::new();
        for (render_chunk, mic_chunk) in render.chunks(chunk_size).zip(mic.chunks(chunk_size)) {
            reference.push_render_chunk(render_chunk);
            let cleaned = processor.process_chunk(mic_chunk);
            all_cleaned.extend_from_slice(&cleaned);
        }

        let tail_start = 32_000;
        let raw_e = energy(&mic[tail_start..]);
        let clean_e = energy(&all_cleaned[tail_start..]);
        let ratio = clean_e / raw_e;
        assert!(
            ratio < 0.20,
            "delayed echo energy should be < 20% after convergence, got {:.2}%",
            ratio * 100.0
        );
    }

    #[test]
    fn freq_domain_aec_preserves_mic_when_reference_silent() {
        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());

        let silence = vec![0.0f32; 4800];
        reference.push_render_chunk(&silence);

        let mic: Vec<f32> = (0..4800).map(|i| ((i as f32) * 0.11).sin() * 0.3).collect();

        let mut all_cleaned = Vec::new();
        for chunk in mic.chunks(480) {
            reference.push_render_chunk(&vec![0.0; chunk.len()]);
            let cleaned = processor.process_chunk(chunk);
            all_cleaned.extend_from_slice(&cleaned);
        }

        let ratio = energy(&all_cleaned) / energy(&mic);
        assert!(
            ratio > 0.95,
            "mic should pass through when reference silent, got {:.2}%",
            ratio * 100.0
        );
    }

    #[test]
    fn freq_domain_aec_resets_after_prolonged_silence() {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let reference = EchoReferenceBuffer::new(1_000);
        let mut processor = MicEchoProcessor::new(reference.clone());

        for i in 0..125 {
            let offset = i * 256;
            let render: Vec<f32> = (0..256)
                .map(|j| {
                    let mut h = DefaultHasher::new();
                    (offset + j).hash(&mut h);
                    (h.finish() as f32 / u64::MAX as f32) * 2.0 - 1.0
                })
                .collect();
            let mic: Vec<f32> = render.iter().map(|&s| s * 0.5).collect();
            reference.push_render_chunk(&render);
            processor.process_chunk(&mic);
        }

        for _ in 0..63 {
            let silence = vec![0.0f32; 256];
            reference.push_render_chunk(&silence);
            processor.process_chunk(&silence);
        }

        let new_mic: Vec<f32> = (0..4800).map(|i| ((i as f32) * 0.07).sin() * 0.3).collect();
        let mut all_cleaned = Vec::new();
        for chunk in new_mic.chunks(480) {
            reference.push_render_chunk(&vec![0.0; chunk.len()]);
            let cleaned = processor.process_chunk(chunk);
            all_cleaned.extend_from_slice(&cleaned);
        }

        let ratio = energy(&all_cleaned) / energy(&new_mic);
        assert!(
            ratio < 1.2,
            "output should not have artifacts after silence reset, energy ratio {:.2}",
            ratio
        );
        assert!(
            ratio > 0.7,
            "output should not be excessively suppressed, energy ratio {:.2}",
            ratio
        );
    }
}
