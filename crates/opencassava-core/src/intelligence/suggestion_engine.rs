use crate::intelligence::llm_client::{strip_fences, Message};
use crate::models::{
    ConversationState, KBResult, Suggestion, SuggestionDecision, SuggestionKind, Utterance,
};
use std::collections::HashSet;
use std::time::{Duration, Instant};

const COOLDOWN_SECS: u64 = 90;
const MIN_WORDS: usize = 8;
const MIN_CHARS: usize = 30;
const MAX_RECENT_ANGLES: usize = 3;

pub struct SuggestionEngine {
    pub conversation_state: ConversationState,
    recent_suggestion_texts: Vec<String>,
    surfaced_smart_questions: HashSet<String>,
    last_suggestion_time: Option<Instant>,
    utterance_count: usize,
}

impl SuggestionEngine {
    pub fn new() -> Self {
        Self {
            conversation_state: ConversationState::empty(),
            recent_suggestion_texts: Vec::new(),
            surfaced_smart_questions: HashSet::new(),
            last_suggestion_time: None,
            utterance_count: 0,
        }
    }

    /// Process a recent transcript window through the suggestion pipeline.
    /// Returns a Suggestion if one should be surfaced, None otherwise.
    ///
    /// `embed_fn`: takes a batch of texts, returns embeddings
    /// `search_fn`: takes query embedding, returns KB results
    /// `complete_fn`: takes messages, returns LLM completion text
    pub async fn process_transcript_window<EmbedFn, EmbedFut, SearchFn, CompleteFn, CompleteFut>(
        &mut self,
        transcript_window: &str,
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
        if !self.passes_prefilter(transcript_window) {
            return None;
        }

        // Stage 2: Refresh conversation state from the current rolling window.
        self.update_conversation_state(recent_them_utterances, &complete_fn)
            .await;

        // Stage 3: KB retrieval
        let queries = self.build_search_queries(transcript_window);
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
                .maybe_surface_smart_question(
                    transcript_window,
                    recent_them_utterances,
                    &complete_fn,
                )
                .await;
        }

        // Stage 4: LLM surfacing gate
        let decision = self
            .run_surfacing_gate(transcript_window, &kb_hits, &complete_fn)
            .await?;

        if !decision.should_surface {
            return None;
        }

        let suggestion_text = self
            .synthesize_suggestion(transcript_window, &kb_hits, &complete_fn)
            .await?;

        // Track recent suggestions to avoid duplicates
        self.register_recent_suggestion(suggestion_text.clone());

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
        self.surfaced_smart_questions.clear();
        self.last_suggestion_time = None;
        self.utterance_count = 0;
    }

    // -- Private helpers -------------------------------------------------------

    fn passes_prefilter(&self, text: &str) -> bool {
        let words: Vec<&str> = text.split_whitespace().collect();
        if words.len() < MIN_WORDS || text.len() < MIN_CHARS {
            return false;
        }
        if let Some(t) = self.last_suggestion_time {
            if t.elapsed() < Duration::from_secs(COOLDOWN_SECS) {
                return false;
            }
        }
        true
    }

    fn build_search_queries(&self, transcript_window: &str) -> Vec<String> {
        let mut queries = vec![transcript_window.to_string()];
        if !self.conversation_state.current_topic.is_empty() {
            queries.push(format!(
                "{} {}",
                self.conversation_state.current_topic, transcript_window
            ));
        }
        if !self.conversation_state.short_summary.is_empty() {
            queries.push(self.conversation_state.short_summary.clone());
        }
        queries
    }

    fn register_recent_suggestion(&mut self, text: String) {
        self.recent_suggestion_texts.push(text);
        if self.recent_suggestion_texts.len() > MAX_RECENT_ANGLES {
            self.recent_suggestion_texts.remove(0);
        }
        self.last_suggestion_time = Some(Instant::now());
    }

    fn normalize_question(text: &str) -> String {
        text.split_whitespace()
            .map(|part| part.trim_matches(|c: char| c.is_ascii_punctuation()))
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase()
    }

    fn has_already_surfaced_question(&self, question: &str) -> bool {
        let normalized = Self::normalize_question(question);
        !normalized.is_empty() && self.surfaced_smart_questions.contains(&normalized)
    }

    async fn update_conversation_state<F, Fut>(
        &mut self,
        recent_them: &[&Utterance],
        complete_fn: &F,
    ) where
        F: Fn(Vec<Message>) -> Fut,
        Fut: std::future::Future<Output = Result<String, String>>,
    {
        let transcript = recent_them
            .iter()
            .map(|u| format!("Them: {}", u.text))
            .collect::<Vec<_>>()
            .join("\n");

        let prompt = format!(
            "Analyze this conversation excerpt and return JSON with fields: \
            currentTopic, shortSummary, openQuestions (array), activeTensions (array), \
            recentDecisions (array), themGoals (array).\n\nTranscript:\n{}",
            transcript
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
        transcript_window: &str,
        kb_hits: &[KBResult],
        complete_fn: &F,
    ) -> Option<SuggestionDecision>
    where
        F: Fn(Vec<Message>) -> Fut,
        Fut: std::future::Future<Output = Result<String, String>>,
    {
        let context = kb_hits
            .iter()
            .map(|h| {
                format!(
                    "- {} (score: {:.2})",
                    &h.text[..h.text.len().min(100)],
                    h.score
                )
            })
            .collect::<Vec<_>>()
            .join("\n");

        let recent = self.recent_suggestion_texts.join(", ");

        let prompt = format!(
            "Should we surface a suggestion based on this?\n\
            Recent conversation:\n{transcript_window}\n\
            KB Context:\n{context}\n\
            Recent suggestions: {recent}\n\n\
            Return JSON: {{\"shouldSurface\": bool, \"confidence\": 0-1, \
            \"relevanceScore\": 0-1, \"helpfulnessScore\": 0-1, \
            \"timingScore\": 0-1, \"noveltyScore\": 0-1, \"reason\": \"...\"}}"
        );

        let messages = vec![
            Message::system(
                "You decide if an AI suggestion should be shown. Return only valid JSON.",
            ),
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
        transcript_window: &str,
        kb_hits: &[KBResult],
        complete_fn: &F,
    ) -> Option<String>
    where
        F: Fn(Vec<Message>) -> Fut,
        Fut: std::future::Future<Output = Result<String, String>>,
    {
        let context = kb_hits
            .iter()
            .take(3)
            .map(|h| h.text.clone())
            .collect::<Vec<_>>()
            .join("\n\n");

        let prompt = format!(
            "Given this conversation moment and relevant knowledge, write a concise, \
            actionable suggestion (1-2 sentences) that would help the speaker respond effectively.\n\n\
            Recent conversation:\n{transcript_window}\n\nRelevant knowledge:\n{context}"
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
        let previously_surfaced_questions = self
            .surfaced_smart_questions
            .iter()
            .cloned()
            .collect::<Vec<_>>()
            .join(", ");
        let prompt = format!(
            "A meeting participant may need a clarifying or probing question when there is a knowledge gap, ambiguity, \
            missing constraint, or unstated assumption.\n\
            Current topic: {}\n\
            Short summary: {}\n\
            Recent conversation:\n{}\n\n\
            Most recent utterance: {}\n\
            Recent suggestions: {}\n\
            Previously surfaced smart questions: {}\n\n\
            Return JSON: {{\"shouldSurface\": bool, \"question\": string, \"confidence\": 0-1, \
            \"relevanceScore\": 0-1, \"helpfulnessScore\": 0-1, \"timingScore\": 0-1, \
            \"noveltyScore\": 0-1, \"reason\": string}}.\n\
            The question must be concise, natural, and directly ask for the missing information. \
            Do not repeat a smart question that was already surfaced earlier in the session.",
            self.conversation_state.current_topic,
            self.conversation_state.short_summary,
            recent_context,
            utterance,
            recent,
            previously_surfaced_questions,
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

        if !should_surface || question.is_empty() || self.has_already_surfaced_question(&question) {
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

        self.surfaced_smart_questions
            .insert(Self::normalize_question(&question));
        self.register_recent_suggestion(question.clone());

        Some(Suggestion::new(
            SuggestionKind::SmartQuestion,
            question,
            Vec::new(),
            Some(decision),
        ))
    }
}

impl Default for SuggestionEngine {
    fn default() -> Self {
        Self::new()
    }
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
        let text =
            "What is the best approach to solving this customer problem we keep running into?";
        assert!(engine.passes_prefilter(text));
    }

    #[test]
    fn prefilter_accepts_plain_substantive_statement() {
        let engine = SuggestionEngine::new();
        let text = "Estamos revisando el alcance del proyecto y necesitamos ordenar las prioridades del cliente.";
        assert!(engine.passes_prefilter(text));
    }

    #[test]
    fn normalize_question_ignores_case_whitespace_and_punctuation() {
        let normalized = SuggestionEngine::normalize_question("  What is the budget timeline?  ");
        assert_eq!(normalized, "what is the budget timeline");
    }

    #[test]
    fn surfaced_question_match_uses_normalized_text() {
        let mut engine = SuggestionEngine::new();
        engine
            .surfaced_smart_questions
            .insert(SuggestionEngine::normalize_question(
                "What is the budget timeline?",
            ));

        assert!(engine.has_already_surfaced_question("what is the budget timeline"));
        assert!(engine.has_already_surfaced_question("What is the budget timeline?!"));
        assert!(!engine.has_already_surfaced_question("Who owns the budget timeline?"));
    }
}
