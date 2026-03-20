use reqwest::Client;
use serde::{Deserialize, Serialize};

/// Shared request/response shape (OpenAI-compatible /v1/embeddings).
#[derive(Serialize)]
struct EmbedRequest<'a> {
    model: &'a str,
    input: &'a [String],
    #[serde(skip_serializing_if = "Option::is_none")]
    input_type: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    output_dimension: Option<u32>,
}

#[derive(Deserialize)]
struct EmbedResponse {
    data: Vec<EmbedItem>,
}

#[derive(Deserialize)]
struct EmbedItem {
    index: usize,
    embedding: Vec<f32>,
}

/// Embed a batch of texts using an OpenAI-compatible /v1/embeddings endpoint.
///
/// - `base_url`: e.g. "https://api.voyageai.com/v1", "http://localhost:11434/v1"
/// - `api_key`: Some("sk-...") or None for local Ollama
/// - `input_type`: Some("query") or Some("document") for Voyage; None for others
/// - `dimensions`: Some(256) for Voyage; None for default
///
/// Returns embeddings in the same order as input texts.
pub async fn embed(
    base_url: &str,
    api_key: Option<&str>,
    model: &str,
    texts: &[String],
    input_type: Option<&str>,
    dimensions: Option<u32>,
) -> Result<Vec<Vec<f32>>, String> {
    let url = format!("{}/embeddings", base_url.trim_end_matches('/'));
    let body = EmbedRequest {
        model,
        input: texts,
        input_type,
        output_dimension: dimensions,
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
        return Err(format!(
            "Embed HTTP {}: {}",
            resp.status(),
            resp.text().await.unwrap_or_default()
        ));
    }

    let parsed: EmbedResponse = resp.json().await.map_err(|e| e.to_string())?;
    let mut items = parsed.data;
    items.sort_by_key(|e| e.index);
    Ok(items.into_iter().map(|e| e.embedding).collect())
}

/// Compute cosine similarity between two equal-length vectors.
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let mag_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let mag_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if mag_a == 0.0 || mag_b == 0.0 {
        0.0
    } else {
        dot / (mag_a * mag_b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cosine_identical_vectors() {
        let v = vec![1.0, 2.0, 3.0];
        let sim = cosine_similarity(&v, &v);
        assert!(
            (sim - 1.0).abs() < 1e-5,
            "identical vectors should have similarity 1.0, got {sim}"
        );
    }

    #[test]
    fn cosine_orthogonal_vectors() {
        let a = vec![1.0, 0.0];
        let b = vec![0.0, 1.0];
        let sim = cosine_similarity(&a, &b);
        assert!(
            sim.abs() < 1e-5,
            "orthogonal vectors should have similarity 0.0, got {sim}"
        );
    }

    #[test]
    fn cosine_zero_vector() {
        let a = vec![0.0, 0.0];
        let b = vec![1.0, 0.0];
        assert_eq!(cosine_similarity(&a, &b), 0.0);
    }
}
