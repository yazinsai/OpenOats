use crate::models::{MeetingTemplate, SessionRecord, Speaker};

const MAX_TRANSCRIPT_CHARS: usize = 60_000;

/// Format a transcript slice as a human-readable string for the LLM prompt.
pub fn format_transcript(records: &[SessionRecord]) -> String {
    records
        .iter()
        .map(|r| {
            let label = match r.speaker {
                Speaker::You => "You",
                Speaker::Them => "Them",
            };
            let ts = r.timestamp.format("%H:%M:%S");
            format!("[{ts}] {label}: {}", r.text)
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
    on_chunk: F,
) -> Result<String, String>
where
    F: Fn(String),
{
    let raw = format_transcript(records);
    let transcript = truncate_transcript(&raw);

    let messages = vec![
        crate::intelligence::llm_client::Message::system(&template.system_prompt),
        crate::intelligence::llm_client::Message::user(format!(
            "Here is the meeting transcript:\n\n{}",
            transcript
        )),
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
