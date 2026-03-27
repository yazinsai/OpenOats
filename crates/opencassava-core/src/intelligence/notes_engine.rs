use crate::models::{MeetingTemplate, SessionRecord};

/// Returns a language instruction string to append to LLM prompts.
/// Empty string means no instruction needed (e.g. auto-detect or English).
pub fn language_response_instruction(locale: &str) -> String {
    let locale = locale.trim().to_ascii_lowercase();
    if locale.is_empty() || locale == "auto" || locale.starts_with("en") {
        return String::new();
    }
    "IMPORTANT: Write your entire response in the same language as the transcript above."
        .to_string()
}

const MAX_TRANSCRIPT_CHARS: usize = 60_000;

/// Format a transcript slice as a human-readable string for the LLM prompt.
pub fn format_transcript(records: &[SessionRecord]) -> String {
    records
        .iter()
        .map(|r| {
            let ts = r.timestamp.format("%H:%M:%S");
            format!("[{ts}] {}: {}", r.display_label(), r.text)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Truncate transcript text to MAX_TRANSCRIPT_CHARS keeping start + end.
fn truncate_transcript(text: &str) -> String {
    if text.len() <= MAX_TRANSCRIPT_CHARS {
        return text.to_string();
    }
    let third = MAX_TRANSCRIPT_CHARS / 3;
    let start = &text[..third];
    let end = &text[text.len() - third * 2..];
    format!("{}\n\n[... transcript truncated ...]\n\n{}", start, end)
}

/// Generate meeting notes by streaming an LLM completion.
/// Returns the full markdown string.
/// `on_chunk` is called for each streamed token (for live display).
pub async fn generate_notes<F>(
    records: &[SessionRecord],
    template: &MeetingTemplate,
    base_url: &str,
    api_key: Option<&str>,
    model: &str,
    language: &str,
    on_chunk: F,
) -> Result<String, String>
where
    F: Fn(String),
{
    let raw = format_transcript(records);
    let transcript = truncate_transcript(&raw);

    let language_instruction = language_response_instruction(language);
    let user_message = if language_instruction.is_empty() {
        format!("Here is the meeting transcript:\n\n{}", transcript)
    } else {
        format!(
            "Here is the meeting transcript:\n\n{}\n\n{}",
            transcript, language_instruction
        )
    };

    let messages = vec![
        crate::intelligence::llm_client::Message::system(&template.system_prompt),
        crate::intelligence::llm_client::Message::user(user_message),
    ];

    crate::intelligence::llm_client::stream_completion(
        base_url, api_key, model, messages, 4096, on_chunk,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Speaker;
    use chrono::Utc;

    fn make_record(speaker: Speaker, text: &str) -> SessionRecord {
        SessionRecord {
            speaker,
            participant_id: None,
            participant_label: None,
            text: text.into(),
            timestamp: Utc::now(),
            suggestions: None,
            kb_hits: None,
            suggestion_decision: None,
            surfaced_suggestion_text: None,
            conversation_state_summary: None,
        }
    }

    #[test]
    fn format_transcript_labels_speakers() {
        let records = vec![
            make_record(Speaker::You, "hello"),
            make_record(Speaker::Them, "hi there"),
        ];
        let text = format_transcript(&records);
        assert!(text.contains("You: hello"));
        assert!(text.contains("Them: hi there"));
    }

    #[test]
    fn format_transcript_prefers_participant_label() {
        let mut record = make_record(Speaker::Them, "hi there");
        record.participant_label = Some("Speaker A".into());
        let text = format_transcript(&[record]);
        assert!(text.contains("Speaker A: hi there"));
    }

    #[test]
    fn truncate_leaves_short_transcript_intact() {
        let text = "short text";
        assert_eq!(truncate_transcript(text), text);
    }

    #[test]
    fn truncate_long_transcript_keeps_start_and_end() {
        let long = "a".repeat(MAX_TRANSCRIPT_CHARS + 1000);
        let result = truncate_transcript(&long);
        assert!(result.len() < long.len());
        assert!(result.contains("[... transcript truncated ...]"));
    }
}
