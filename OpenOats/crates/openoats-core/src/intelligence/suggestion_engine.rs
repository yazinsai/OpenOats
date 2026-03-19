use crate::intelligence::llm_client::{strip_fences, Message};
use crate::models::{
    ConversationState, KBResult, Suggestion, SuggestionDecision, SuggestionKind, Utterance,
};
use std::time::{Duration, Instant};

const COOLDOWN_SECS: u64 = 90;
const MIN_WORDS: usize = 8;
const MIN_CHARS: usize = 30;
const MAX_RECENT_ANGLES: usize = 3;

pub struct SuggestionEngine {
    pub conversation_state: ConversationState,
    recent_suggestion_texts: Vec<String>,
    last_suggestion_time: Option<Instant>,
    utterance_count: usize,
}

impl SuggestionEngine {
    pub fn new() -> Self {
        Self {
            conversation_state: ConversationState::empty(),
            recent_suggestion_texts: Vec::new(),
            last_suggestion_time: None,
            utterance_count: 0,
        }
    }

    /// Process a "them" utterance through the suggestion pipeline.
    /// Returns a Suggestion if one should be surfaced, None otherwise.
    ///
    /// `embed_fn`: takes a batch of texts, returns embeddings
    /// `search_fn`: takes query embedding, returns KB results
    /// `complete_fn`: takes messages, returns LLM completion text
    pub async fn process_utterance<EmbedFn, EmbedFut, SearchFn, CompleteFn, CompleteFut>(
        &mut self,
        utterance: &Utterance,
        recent_them_utterances: &[&Utterance],
        embed_fn: EmbedFn,
        search_fn: SearchFn,
        complete_fn: CompleteFn,
    ) -> Option<Suggestion>
    where
        EmbedFn: Fn(Vec<String>) -> EmbedFut,
        EmbedFut: std::future::Future<Output = Result<Vec<Vec<f32>>, String>>,
        SearchFn: Fn(&[f32]) -> Vec<KBResult>,
        CompleteFn: Fn(Vec<Message>) -> CompleteFut,
        CompleteFut: std::future::Future<Output = Result<String, String>>,
    {
        self.utterance_count += 1;

        // Stage 1: Heuristic pre-filter
        if !self.passes_prefilter(&utterance.text) {
            return None;
        }

        // Stage 2: Trigger detection
        if !self.has_trigger(&utterance.text) {
            return None;
        }

        // Stage 3: Update conversation state every 2-3 them utterances
        if self.utterance_count % 3 == 0 {
            self.update_conversation_state(recent_them_utterances, &complete_fn).await;
        }

        // Stage 4: KB retrieval
        let queries = self.build_search_queries(&utterance.text);
        let mut kb_hits: Vec<KBResult> = Vec::new();
        for q in &queries {
            if let Ok(embeddings) = embed_fn(vec![q.clone()]).await {
                if let Some(emb) = embeddings.into_iter().next() {
                    let results = search_fn(&emb);
                    for r in results {
                        if !kb_hits.iter().any(|h: &KBResult| h.text == r.text) {
                            kb_hits.push(r);
                        }
                    }
                }
            }
        }

        if kb_hits.is_empty() {
            return self
                .maybe_surface_smart_question(&utterance.text, recent_them_utterances, &complete_fn)
                .await;
        }

        // Stage 5: LLM surfacing gate
        let decision = self.run_surfacing_gate(&utterance.text, &kb_hits, &complete_fn).await?;

        if !decision.should_surface {
            return None;
        }

        let suggestion_text = self.synthesize_suggestion(&utterance.text, &kb_hits, &complete_fn).await?;

        // Track recent suggestions to avoid duplicates
        self.recent_suggestion_texts.push(suggestion_text.clone());
        if self.recent_suggestion_texts.len() > MAX_RECENT_ANGLES {
            self.recent_suggestion_texts.remove(0);
        }
        self.last_suggestion_time = Some(Instant::now());

        Some(Suggestion::new(
            SuggestionKind::KnowledgeBase,
            suggestion_text,
            kb_hits,
            Some(decision),
        ))
    }

    pub fn clear(&mut self) {
        self.conversation_state = ConversationState::empty();
        self.recent_suggestion_texts.clear();
        self.last_suggestion_time = None;
        self.utterance_count = 0;
    }

    // -- Private helpers -------------------------------------------------------

    fn passes_prefilter(&self, text: &str) -> bool {
        let words: Vec<&str> = text.split_whitespace().collect();
        if words.len() < MIN_WORDS || text.len() < MIN_CHARS { return false; }
        if let Some(t) = self.last_suggestion_time {
            if t.elapsed() < Duration::from_secs(COOLDOWN_SECS) { return false; }
        }
        true
    }

    fn has_trigger(&self, text: &str) -> bool {
        let lower = text.to_lowercase();
        // Explicit questions
        if lower.contains('?') { return true; }
        let question_starters = [
            "what ", "how ", "why ", "when ", "where ", "who ", "which ",
            "can we", "can you", "could we", "could you", "would you",
            "do we", "do you", "is there", "are there", "have we", "have you",
        ];
        if question_starters.iter().any(|w| lower.starts_with(w) || lower.contains(&format!(" {}", w))) {
            return true;
        }
        // Decision points
        let decision_words = ["should we", "pick between", "which option", "how do we", "what should", "best approach"];
        if decision_words.iter().any(|w| lower.contains(w)) { return true; }
        // Problem signals
        let problem_words = ["problem", "challenge", "struggle", "difficult", "can't figure", "not sure how"];
        if problem_words.iter().any(|w| lower.contains(w)) { return true; }
        // Knowledge-gap signals that should route into smart-question generation
        let knowledge_gap_words = [
            "not clear",
            "unclear",
            "depends on",
            "need to know",
            "don't know",
            "do not know",
            "unknown",
            "missing",
            "haven't decided",
            "have not decided",
            "still figuring out",
            "not sure yet",
        ];
        if knowledge_gap_words.iter().any(|w| lower.contains(w)) { return true; }
        false
    }

    fn build_search_queries(&self, utterance: &str) -> Vec<String> {
        let mut queries = vec![utterance.to_string()];
        if !self.conversation_state.current_topic.is_empty() {
            queries.push(format!("{} {}", self.conversation_state.current_topic, utterance));
        }
        if !self.conversation_state.short_summary.is_empty() {
            queries.push(self.conversation_state.short_summary.clone());
        }
        queries
    }

    async fn update_conversation_state<F, Fut>(
        &mut self,
        recent_them: &[&Utterance],
        complete_fn: &F,
    )
    where
        F: Fn(Vec<Message>) -> Fut,
        Fut: std::future::Future<Output = Result<String, String>>,
    {
        let transcript = recent_them.iter()
            .map(|u| format!("Them: {}", u.text))
            .collect::<Vec<_>>().join("\n");

        let prompt = format!(
            "Analyze this conversation excerpt and return JSON with fields: \
            currentTopic, shortSummary, openQuestions (array), activeTensions (array), \
            recentDecisions (array), themGoals (array).\n\nTranscript:\n{}", transcript
        );

        let messages = vec![
            Message::system("You are a conversation analyst. Return only valid JSON."),
            Message::user(prompt),
        ];

        if let Ok(raw) = complete_fn(messages).await {
            let clean = strip_fences(&raw);
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(clean) {
                if let Some(t) = v["currentTopic"].as_str() {
                    self.conversation_state.current_topic = t.to_string();
                }
                if let Some(s) = v["shortSummary"].as_str() {
                    self.conversation_state.short_summary = s.to_string();
                }
                self.conversation_state.last_updated_at = chrono::Utc::now();
            }
        }
    }

    async fn run_surfacing_gate<F, Fut>(
        &self,
        utterance: &str,
        kb_hits: &[KBResult],
        complete_fn: &F,
    ) -> Option<SuggestionDecision>
    where
        F: Fn(Vec<Message>) -> Fut,
        Fut: std::future::Future<Output = Result<String, String>>,
    {
        let context = kb_hits.iter()
            .map(|h| format!("- {} (score: {:.2})", &h.text[..h.text.len().min(100)], h.score))
            .collect::<Vec<_>>().join("\n");

        let recent = self.recent_suggestion_texts.join(", ");

        let prompt = format!(
            "Should we surface a suggestion based on this?\n\
            Utterance: {utterance}\n\
            KB Context:\n{context}\n\
            Recent suggestions: {recent}\n\n\
            Return JSON: {{\"shouldSurface\": bool, \"confidence\": 0-1, \
            \"relevanceScore\": 0-1, \"helpfulnessScore\": 0-1, \
            \"timingScore\": 0-1, \"noveltyScore\": 0-1, \"reason\": \"...\"}}"
        );

        let messages = vec![
            Message::system("You decide if an AI suggestion should be shown. Return only valid JSON."),
            Message::user(prompt),
        ];

        let raw = complete_fn(messages).await.ok()?;
        let clean = strip_fences(&raw);
        let v: serde_json::Value = serde_json::from_str(clean).ok()?;

        let should_surface = v["shouldSurface"].as_bool().unwrap_or(false);
        let confidence = v["confidence"].as_f64().unwrap_or(0.0);

        Some(SuggestionDecision {
            should_surface,
            confidence,
            relevance_score: v["relevanceScore"].as_f64().unwrap_or(0.0),
            helpfulness_score: v["helpfulnessScore"].as_f64().unwrap_or(0.0),
            timing_score: v["timingScore"].as_f64().unwrap_or(0.0),
            novelty_score: v["noveltyScore"].as_f64().unwrap_or(0.0),
            reason: v["reason"].as_str().unwrap_or("").to_string(),
        })
    }

    async fn synthesize_suggestion<F, Fut>(
        &self,
        utterance: &str,
        kb_hits: &[KBResult],
        complete_fn: &F,
    ) -> Option<String>
    where
        F: Fn(Vec<Message>) -> Fut,
        Fut: std::future::Future<Output = Result<String, String>>,
    {
        let context = kb_hits.iter().take(3)
            .map(|h| h.text.clone())
            .collect::<Vec<_>>().join("\n\n");

        let prompt = format!(
            "Given this conversation moment and relevant knowledge, write a concise, \
            actionable suggestion (1-2 sentences) that would help the speaker respond effectively.\n\n\
            What was said: {utterance}\n\nRelevant knowledge:\n{context}"
        );

        let messages = vec![
            Message::system("You write brief, helpful suggestions for meeting participants."),
            Message::user(prompt),
        ];

        complete_fn(messages).await.ok()
    }

    async fn maybe_surface_smart_question<F, Fut>(
        &mut self,
        utterance: &str,
        recent_them_utterances: &[&Utterance],
        complete_fn: &F,
    ) -> Option<Suggestion>
    where
        F: Fn(Vec<Message>) -> Fut,
        Fut: std::future::Future<Output = Result<String, String>>,
    {
        let recent_context = recent_them_utterances
            .iter()
            .rev()
            .take(3)
            .rev()
            .map(|u| format!("Them: {}", u.text))
            .collect::<Vec<_>>()
            .join("\n");

        let recent = self.recent_suggestion_texts.join(", ");
        let prompt = format!(
            "A meeting participant may need a clarifying or probing question when there is a knowledge gap, ambiguity, \
            missing constraint, or unstated assumption.\n\
            Current topic: {}\n\
            Short summary: {}\n\
            Recent conversation:\n{}\n\n\
            Most recent utterance: {}\n\
            Recent suggestions: {}\n\n\
            Return JSON: {{\"shouldSurface\": bool, \"question\": string, \"confidence\": 0-1, \
            \"relevanceScore\": 0-1, \"helpfulnessScore\": 0-1, \"timingScore\": 0-1, \
            \"noveltyScore\": 0-1, \"reason\": string}}.\n\
            The question must be concise, natural, and directly ask for the missing information.",
            self.conversation_state.current_topic,
            self.conversation_state.short_summary,
            recent_context,
            utterance,
            recent,
        );

        let messages = vec![
            Message::system("You decide when a smart clarifying question should be suggested. Return only valid JSON."),
            Message::user(prompt),
        ];

        let raw = complete_fn(messages).await.ok()?;
        let clean = strip_fences(&raw);
        let v: serde_json::Value = serde_json::from_str(clean).ok()?;

        let should_surface = v["shouldSurface"].as_bool().unwrap_or(false);
        let question = v["question"].as_str().unwrap_or("").trim().to_string();

        if !should_surface || question.is_empty() {
            return None;
        }

        let decision = SuggestionDecision {
            should_surface,
            confidence: v["confidence"].as_f64().unwrap_or(0.0),
            relevance_score: v["relevanceScore"].as_f64().unwrap_or(0.0),
            helpfulness_score: v["helpfulnessScore"].as_f64().unwrap_or(0.0),
            timing_score: v["timingScore"].as_f64().unwrap_or(0.0),
            novelty_score: v["noveltyScore"].as_f64().unwrap_or(0.0),
            reason: v["reason"].as_str().unwrap_or("").to_string(),
        };

        self.recent_suggestion_texts.push(question.clone());
        if self.recent_suggestion_texts.len() > MAX_RECENT_ANGLES {
            self.recent_suggestion_texts.remove(0);
        }
        self.last_suggestion_time = Some(Instant::now());

        Some(Suggestion::new(
            SuggestionKind::SmartQuestion,
            question,
            Vec::new(),
            Some(decision),
        ))
    }
}

impl Default for SuggestionEngine {
    fn default() -> Self { Self::new() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefilter_rejects_short_text() {
        let engine = SuggestionEngine::new();
        assert!(!engine.passes_prefilter("hi"));
    }

    #[test]
    fn prefilter_accepts_substantive_text() {
        let engine = SuggestionEngine::new();
        let text = "What is the best approach to solving this customer problem we keep running into?";
        assert!(engine.passes_prefilter(text));
    }

    #[test]
    fn has_trigger_detects_question_mark() {
        let engine = SuggestionEngine::new();
        assert!(engine.has_trigger("How should we approach this?"));
    }

    #[test]
    fn has_trigger_detects_problem_signal() {
        let engine = SuggestionEngine::new();
        assert!(engine.has_trigger("We have a problem with the current architecture."));
    }

    #[test]
    fn has_trigger_rejects_plain_statement() {
        let engine = SuggestionEngine::new();
        assert!(!engine.has_trigger("We are working on the feature today."));
    }
}
