use whisper_rs::{
    FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState,
};

pub struct WhisperManager {
    ctx: WhisperContext,
    language: String,
}

impl WhisperManager {
    pub fn new(model_path: &str, language: &str) -> Result<Self, String> {
        let ctx = WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
            .map_err(|e| format!("Failed to load whisper model: {e}"))?;
        Ok(Self {
            ctx,
            language: language.to_string(),
        })
    }

    pub fn create_state(&self) -> Result<WhisperState, String> {
        self.ctx.create_state().map_err(|e| e.to_string())
    }

    pub fn transcribe(state: &mut WhisperState, samples: &[f32], language: &str) -> String {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 0 });
        params.set_n_threads(4);
        params.set_language(Some(language));
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_single_segment(false);
        params.set_no_context(true);
        params.set_suppress_blank(true);

        if state.full(params, samples).is_err() {
            return String::new();
        }

        let n = state.full_n_segments().unwrap_or(0);
        let mut text = String::new();
        for i in 0..n {
            if let Ok(seg) = state.full_get_segment_text(i) {
                text.push_str(&seg);
            }
        }
        text.trim().to_string()
    }

    pub fn language(&self) -> &str {
        &self.language
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whisper_manager_requires_valid_path() {
        let result = WhisperManager::new("/nonexistent/path/model.bin", "en");
        assert!(result.is_err());
    }
}
