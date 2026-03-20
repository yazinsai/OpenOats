use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ── Speaker ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Speaker {
    You,
    Them,
}

impl Speaker {
    pub fn label(&self) -> &'static str {
        match self {
            Speaker::You => "you",
            Speaker::Them => "them",
        }
    }
}

// ── Utterance ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Utterance {
    pub id: Uuid,
    pub text: String,
    pub speaker: Speaker,
    pub timestamp: DateTime<Utc>,
}

impl Utterance {
    pub fn new(text: String, speaker: Speaker) -> Self {
        Self {
            id: Uuid::new_v4(),
            text,
            speaker,
            timestamp: Utc::now(),
        }
    }
}

// ── ConversationState ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ConversationState {
    pub current_topic: String,
    pub short_summary: String,
    pub open_questions: Vec<String>,
    pub active_tensions: Vec<String>,
    pub recent_decisions: Vec<String>,
    pub them_goals: Vec<String>,
    pub suggested_angles_recently_shown: Vec<String>,
    pub last_updated_at: DateTime<Utc>,
}

impl ConversationState {
    pub fn empty() -> Self {
        Self {
            last_updated_at: DateTime::<Utc>::from_timestamp(0, 0).unwrap(),
            ..Default::default()
        }
    }
}

// ── SuggestionDecision ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SuggestionDecision {
    pub should_surface: bool,
    pub confidence: f64,
    pub relevance_score: f64,
    pub helpfulness_score: f64,
    pub timing_score: f64,
    pub novelty_score: f64,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SuggestionKind {
    KnowledgeBase,
    SmartQuestion,
}

// ── KBResult ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KBResult {
    pub id: Uuid,
    pub text: String,
    pub source_file: String,
    pub header_context: String,
    pub score: f64,
}

impl KBResult {
    pub fn new(text: String, source_file: String, header_context: String, score: f64) -> Self {
        Self {
            id: Uuid::new_v4(),
            text,
            source_file,
            header_context,
            score,
        }
    }
}

// ── Suggestion ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Suggestion {
    pub id: Uuid,
    pub kind: SuggestionKind,
    pub text: String,
    pub timestamp: DateTime<Utc>,
    pub kb_hits: Vec<KBResult>,
    pub decision: Option<SuggestionDecision>,
    pub summary_snapshot: Option<String>,
}

impl Suggestion {
    pub fn new(
        kind: SuggestionKind,
        text: String,
        kb_hits: Vec<KBResult>,
        decision: Option<SuggestionDecision>,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            kind,
            text,
            timestamp: Utc::now(),
            kb_hits,
            decision,
            summary_snapshot: None,
        }
    }
}

// ── SessionRecord (JSONL line) ────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionRecord {
    pub speaker: Speaker,
    pub text: String,
    pub timestamp: DateTime<Utc>,
    pub suggestions: Option<Vec<String>>,
    pub kb_hits: Option<Vec<String>>,
    pub suggestion_decision: Option<SuggestionDecision>,
    pub surfaced_suggestion_text: Option<String>,
    pub conversation_state_summary: Option<String>,
}

// ── MeetingTemplate ───────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeetingTemplate {
    pub id: Uuid,
    pub name: String,
    pub icon: String,
    pub system_prompt: String,
    pub is_built_in: bool,
}

impl MeetingTemplate {
    pub fn built_ins() -> Vec<Self> {
        vec![
            Self {
                id: Uuid::parse_str("00000000-0000-0000-0000-000000000000").unwrap(),
                name: "Generic".into(),
                icon: "doc.text".into(),
                system_prompt: GENERIC_PROMPT.into(),
                is_built_in: true,
            },
            Self {
                id: Uuid::parse_str("00000000-0000-0000-0000-000000000001").unwrap(),
                name: "1:1".into(),
                icon: "person.2".into(),
                system_prompt: ONE_ON_ONE_PROMPT.into(),
                is_built_in: true,
            },
            Self {
                id: Uuid::parse_str("00000000-0000-0000-0000-000000000002").unwrap(),
                name: "Customer Discovery".into(),
                icon: "magnifyingglass".into(),
                system_prompt: DISCOVERY_PROMPT.into(),
                is_built_in: true,
            },
            Self {
                id: Uuid::parse_str("00000000-0000-0000-0000-000000000003").unwrap(),
                name: "Hiring".into(),
                icon: "person.badge.plus".into(),
                system_prompt: HIRING_PROMPT.into(),
                is_built_in: true,
            },
            Self {
                id: Uuid::parse_str("00000000-0000-0000-0000-000000000004").unwrap(),
                name: "Stand-Up".into(),
                icon: "arrow.up.circle".into(),
                system_prompt: STANDUP_PROMPT.into(),
                is_built_in: true,
            },
            Self {
                id: Uuid::parse_str("00000000-0000-0000-0000-000000000005").unwrap(),
                name: "Weekly Meeting".into(),
                icon: "calendar".into(),
                system_prompt: WEEKLY_PROMPT.into(),
                is_built_in: true,
            },
        ]
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemplateSnapshot {
    pub id: Uuid,
    pub name: String,
    pub icon: String,
    pub system_prompt: String,
}

impl From<&MeetingTemplate> for TemplateSnapshot {
    fn from(t: &MeetingTemplate) -> Self {
        Self {
            id: t.id,
            name: t.name.clone(),
            icon: t.icon.clone(),
            system_prompt: t.system_prompt.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnhancedNotes {
    pub template: TemplateSnapshot,
    pub generated_at: DateTime<Utc>,
    pub markdown: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SuggestionFeedbackEntry {
    pub suggestion_id: String,
    pub helpful: bool,
    pub created_at: DateTime<Utc>,
}

// ── SessionIndex / Sidecar ────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionIndex {
    pub id: String,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub template_snapshot: Option<TemplateSnapshot>,
    pub title: Option<String>,
    pub utterance_count: usize,
    pub has_notes: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSidecar {
    pub index: SessionIndex,
    pub notes: Option<EnhancedNotes>,
    #[serde(default)]
    pub suggestion_feedback: Vec<SuggestionFeedbackEntry>,
}

// ── Built-in template prompts ─────────────────────────────────────────────────

const GENERIC_PROMPT: &str = "You are a meeting notes assistant. Given a transcript of a meeting, produce structured notes in markdown.\n\nInclude these sections:\n## Summary\nA 2-3 sentence overview of what was discussed.\n\n## Key Points\nBullet points of the most important topics and insights.\n\n## Action Items\nBullet points of concrete next steps, with owners if mentioned.\n\n## Decisions Made\nAny decisions that were reached during the meeting.\n\n## Open Questions\nUnresolved questions or topics that need follow-up.";
const ONE_ON_ONE_PROMPT: &str = "You are a meeting notes assistant for a 1:1 meeting. Given a transcript, produce structured notes in markdown.\n\nInclude these sections:\n## Discussion Points\nKey topics that were covered.\n\n## Action Items\nConcrete next steps with owners.\n\n## Follow-ups\nItems that need follow-up in future 1:1s.\n\n## Key Decisions\nDecisions that were made during the meeting.";
const DISCOVERY_PROMPT: &str = "You are a meeting notes assistant for a customer discovery call. Given a transcript, produce structured notes in markdown.\n\nInclude these sections:\n## Customer Profile\nWho the customer is, their role, and context.\n\n## Problems Identified\nPain points and challenges the customer described.\n\n## Current Solutions\nHow they currently solve these problems.\n\n## Key Insights\nSurprising or important learnings from the conversation.\n\n## Next Steps\nFollow-up actions and commitments made.";
const HIRING_PROMPT: &str = "You are a meeting notes assistant for a hiring interview. Given a transcript, produce structured notes in markdown.\n\nInclude these sections:\n## Candidate Summary\nBrief overview of the candidate and role discussed.\n\n## Strengths\nAreas where the candidate demonstrated strong capability.\n\n## Concerns\nPotential red flags or areas needing further evaluation.\n\n## Culture Fit\nObservations about alignment with team/company values.\n\n## Recommendation\nOverall assessment and suggested next steps.";
const STANDUP_PROMPT: &str = "You are a meeting notes assistant for a stand-up meeting. Given a transcript, produce structured notes in markdown.\n\nInclude these sections:\n## Yesterday\nWhat was completed since the last stand-up.\n\n## Today\nWhat each person plans to work on.\n\n## Blockers\nAny obstacles or dependencies that need resolution.";
const WEEKLY_PROMPT: &str = "You are a meeting notes assistant for a weekly team meeting. Given a transcript, produce structured notes in markdown.\n\nInclude these sections:\n## Updates\nStatus updates from team members.\n\n## Decisions Made\nAny decisions that were reached.\n\n## Open Items\nTopics that need further discussion or action.\n\n## Action Items\nConcrete next steps with owners and deadlines if mentioned.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utterance_roundtrips_json() {
        let u = Utterance::new("hello world".into(), Speaker::You);
        let json = serde_json::to_string(&u).unwrap();
        let back: Utterance = serde_json::from_str(&json).unwrap();
        assert_eq!(back.text, "hello world");
        assert_eq!(back.speaker, Speaker::You);
    }

    #[test]
    fn session_record_roundtrips_json() {
        let r = SessionRecord {
            speaker: Speaker::Them,
            text: "test".into(),
            timestamp: Utc::now(),
            suggestions: None,
            kb_hits: None,
            suggestion_decision: None,
            surfaced_suggestion_text: None,
            conversation_state_summary: None,
        };
        let json = serde_json::to_string(&r).unwrap();
        let back: SessionRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(back.text, "test");
        assert_eq!(back.speaker, Speaker::Them);
    }

    #[test]
    fn meeting_template_built_ins_have_stable_ids() {
        let templates = MeetingTemplate::built_ins();
        assert_eq!(templates.len(), 6);
        assert_eq!(
            templates[0].id.to_string(),
            "00000000-0000-0000-0000-000000000000"
        );
    }
}
