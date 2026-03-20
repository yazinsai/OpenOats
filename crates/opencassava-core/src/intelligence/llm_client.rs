use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}

impl Message {
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: "system".into(),
            content: content.into(),
        }
    }
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: "user".into(),
            content: content.into(),
        }
    }
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: &'a [Message],
    stream: bool,
    max_tokens: u32,
}

#[derive(Deserialize)]
struct CompletionResponse {
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: Option<ChoiceMessage>,
    delta: Option<Delta>,
}

#[derive(Deserialize)]
struct ChoiceMessage {
    content: Option<String>,
}

#[derive(Deserialize)]
struct Delta {
    content: Option<String>,
}

/// Non-streaming LLM completion.
/// `base_url` example: "https://openrouter.ai/api/v1" or "http://localhost:11434/v1"
pub async fn complete(
    base_url: &str,
    api_key: Option<&str>,
    model: &str,
    messages: Vec<Message>,
    max_tokens: u32,
) -> Result<String, String> {
    let url = format!("{}/chat/completions", base_url.trim_end_matches('/'));
    let body = ChatRequest {
        model,
        messages: &messages,
        stream: false,
        max_tokens,
    };

    let mut req = Client::new()
        .post(&url)
        .header("Content-Type", "application/json")
        .json(&body);

    if let Some(key) = api_key {
        req = req.header("Authorization", format!("Bearer {}", key));
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("LLM HTTP {}", resp.status()));
    }

    let parsed: CompletionResponse = resp.json().await.map_err(|e| e.to_string())?;
    parsed
        .choices
        .into_iter()
        .next()
        .and_then(|c| c.message)
        .and_then(|m| m.content)
        .ok_or_else(|| "Empty LLM response".into())
}

/// Streaming SSE completion — calls `on_chunk` for each token fragment.
pub async fn stream_completion<F>(
    base_url: &str,
    api_key: Option<&str>,
    model: &str,
    messages: Vec<Message>,
    max_tokens: u32,
    on_chunk: F,
) -> Result<String, String>
where
    F: Fn(String),
{
    use futures::StreamExt;

    let url = format!("{}/chat/completions", base_url.trim_end_matches('/'));
    let body = ChatRequest {
        model,
        messages: &messages,
        stream: true,
        max_tokens,
    };

    let mut req = Client::new()
        .post(&url)
        .header("Content-Type", "application/json")
        .json(&body);

    if let Some(key) = api_key {
        req = req.header("Authorization", format!("Bearer {}", key));
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("LLM stream HTTP {}", resp.status()));
    }

    let mut stream = resp.bytes_stream();
    let mut full_text = String::new();
    let mut buf = String::new();

    while let Some(chunk) = stream.next().await {
        let bytes = chunk.map_err(|e| e.to_string())?;
        buf.push_str(&String::from_utf8_lossy(&bytes));

        // Process complete SSE lines
        while let Some(newline) = buf.find('\n') {
            let line = buf[..newline].trim().to_string();
            buf = buf[newline + 1..].to_string();

            if line.starts_with("data: ") {
                let data = &line[6..];
                if data == "[DONE]" {
                    break;
                }
                if let Ok(parsed) = serde_json::from_str::<CompletionResponse>(data) {
                    if let Some(text) = parsed
                        .choices
                        .into_iter()
                        .next()
                        .and_then(|c| c.delta)
                        .and_then(|d| d.content)
                    {
                        on_chunk(text.clone());
                        full_text.push_str(&text);
                    }
                }
            }
        }
    }

    Ok(full_text)
}

/// Strip markdown code fences from LLM JSON responses.
pub fn strip_fences(s: &str) -> &str {
    let s = s.trim();
    let s = s.strip_prefix("```json").unwrap_or(s);
    let s = s.strip_prefix("```").unwrap_or(s);
    let s = s.strip_suffix("```").unwrap_or(s);
    let s = s.trim();

    let first_object = s.find('{');
    let first_array = s.find('[');
    let start = match (first_object, first_array) {
        (Some(obj), Some(arr)) => obj.min(arr),
        (Some(obj), None) => obj,
        (None, Some(arr)) => arr,
        (None, None) => return s,
    };

    let last_object = s.rfind('}');
    let last_array = s.rfind(']');
    let end = match (last_object, last_array) {
        (Some(obj), Some(arr)) => obj.max(arr),
        (Some(obj), None) => obj,
        (None, Some(arr)) => arr,
        (None, None) => return s,
    };

    if start <= end {
        s[start..=end].trim()
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_fences_removes_markdown() {
        let raw = "```json\n{\"key\": \"val\"}\n```";
        assert_eq!(strip_fences(raw), "{\"key\": \"val\"}");
    }

    #[test]
    fn strip_fences_passthrough_plain() {
        let raw = "{\"key\": \"val\"}";
        assert_eq!(strip_fences(raw), raw);
    }

    #[test]
    fn strip_fences_extracts_json_after_think_block() {
        let raw = "<think>reasoning</think>\n{\"key\": \"val\"}";
        assert_eq!(strip_fences(raw), "{\"key\": \"val\"}");
    }

    #[test]
    fn message_constructors() {
        let s = Message::system("hello");
        assert_eq!(s.role, "system");
        let u = Message::user("world");
        assert_eq!(u.role, "user");
    }
}
