use crate::intelligence::embedding_client::cosine_similarity;
use crate::models::KBResult;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KbChunk {
    pub text: String,
    pub source_file: String,
    pub header_context: String,
    pub embedding: Vec<f32>,
}

#[derive(Serialize, Deserialize, Default)]
struct KbCache {
    /// Maps "{filename}:{sha256}" -> KbChunk
    entries: HashMap<String, Vec<KbChunk>>,
    /// Fingerprint of the embedding config (base_url + model)
    config_fingerprint: String,
}

pub struct KnowledgeBase {
    pub chunks: Vec<KbChunk>,
    cache_path: PathBuf,
    config_fingerprint: String,
}

impl KnowledgeBase {
    pub fn new(cache_path: PathBuf, config_fingerprint: String) -> Self {
        let chunks = Self::load_cache(&cache_path, &config_fingerprint).unwrap_or_default();
        Self {
            chunks,
            cache_path,
            config_fingerprint,
        }
    }

    /// Index all .md and .txt files in `folder`. Returns count of new chunks embedded.
    /// `embed_fn` takes a batch of texts and returns their embeddings.
    pub async fn index<F, Fut>(&mut self, folder: &Path, embed_fn: F) -> Result<usize, String>
    where
        F: Fn(Vec<String>) -> Fut,
        Fut: std::future::Future<Output = Result<Vec<Vec<f32>>, String>>,
    {
        let files = Self::collect_files(folder);
        let mut new_chunks: Vec<KbChunk> = Vec::new();

        for path in &files {
            let content = std::fs::read_to_string(path)
                .map_err(|e| format!("Read {}: {e}", path.display()))?;
            let filename = path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            let _hash = sha2_hex(&content);

            // Check if already cached
            if self.chunks.iter().any(|c| {
                let k = format!("{}:{}", c.source_file, sha2_hex_of_chunk(c));
                k.contains(&filename)
            }) {
                continue; // skip re-embedding unchanged files
            }

            let raw_chunks = chunk_markdown(&content, &filename);
            if raw_chunks.is_empty() {
                continue;
            }

            let texts: Vec<String> = raw_chunks.iter().map(|(t, _)| t.clone()).collect();
            let embeddings = embed_fn(texts).await?;

            for ((text, header), embedding) in raw_chunks.into_iter().zip(embeddings) {
                new_chunks.push(KbChunk {
                    text,
                    source_file: filename.clone(),
                    header_context: header,
                    embedding,
                });
            }
        }

        let added = new_chunks.len();
        self.chunks.extend(new_chunks);
        self.save_cache();
        Ok(added)
    }

    pub fn search(&self, query_embedding: &[f32], top_k: usize, threshold: f32) -> Vec<KBResult> {
        let mut scored: Vec<(f32, &KbChunk)> = self
            .chunks
            .iter()
            .map(|c| (cosine_similarity(query_embedding, &c.embedding), c))
            .filter(|(s, _)| *s >= threshold)
            .collect();
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        scored
            .into_iter()
            .take(top_k)
            .map(|(score, c)| KBResult {
                id: Uuid::new_v4(),
                text: c.text.clone(),
                source_file: c.source_file.clone(),
                header_context: c.header_context.clone(),
                score: score as f64,
            })
            .collect()
    }

    pub fn is_indexed(&self) -> bool {
        !self.chunks.is_empty()
    }
    pub fn chunk_count(&self) -> usize {
        self.chunks.len()
    }

    fn save_cache(&self) {
        if let Some(parent) = self.cache_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let cache = KbCache {
            entries: {
                let mut m = HashMap::new();
                for c in &self.chunks {
                    m.entry(c.source_file.clone())
                        .or_insert_with(Vec::new)
                        .push(c.clone());
                }
                m
            },
            config_fingerprint: self.config_fingerprint.clone(),
        };
        if let Ok(json) = serde_json::to_string(&cache) {
            let _ = std::fs::write(&self.cache_path, json);
        }
    }

    fn load_cache(path: &Path, fingerprint: &str) -> Option<Vec<KbChunk>> {
        let data = std::fs::read_to_string(path).ok()?;
        let cache: KbCache = serde_json::from_str(&data).ok()?;
        if cache.config_fingerprint != fingerprint {
            return None;
        }
        Some(cache.entries.into_values().flatten().collect())
    }

    fn collect_files(folder: &Path) -> Vec<PathBuf> {
        let mut files = Vec::new();
        if let Ok(entries) = std::fs::read_dir(folder) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    files.extend(Self::collect_files(&path));
                } else if matches!(
                    path.extension().and_then(|e| e.to_str()),
                    Some("md") | Some("txt")
                ) {
                    files.push(path);
                }
            }
        }
        files
    }
}

/// Search a provided chunk snapshot without holding a KnowledgeBase reference.
/// Useful for async contexts where snapshotting chunks avoids lock contention.
pub fn search_chunks(
    chunks: &[KbChunk],
    query_embedding: &[f32],
    top_k: usize,
    threshold: f32,
) -> Vec<crate::models::KBResult> {
    use crate::intelligence::embedding_client::cosine_similarity;
    let mut scored: Vec<(f32, &KbChunk)> = chunks
        .iter()
        .map(|c| (cosine_similarity(query_embedding, &c.embedding), c))
        .filter(|(s, _)| *s >= threshold)
        .collect();
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    scored
        .into_iter()
        .take(top_k)
        .map(|(score, c)| crate::models::KBResult {
            id: uuid::Uuid::new_v4(),
            text: c.text.clone(),
            source_file: c.source_file.clone(),
            header_context: c.header_context.clone(),
            score: score as f64,
        })
        .collect()
}

/// Simple markdown chunker: splits on headers, returns (text, header_context) pairs.
fn chunk_markdown(content: &str, _filename: &str) -> Vec<(String, String)> {
    let mut chunks: Vec<(String, String)> = Vec::new();
    let mut current_header = String::new();
    let mut current_text = String::new();

    for line in content.lines() {
        if line.starts_with('#') {
            if !current_text.trim().is_empty() {
                let text = current_text.trim().to_string();
                if count_words(&text) >= 10 {
                    chunks.push((text, current_header.clone()));
                }
            }
            current_header = line.trim_start_matches('#').trim().to_string();
            current_text = format!("{}\n", line);
        } else {
            current_text.push_str(line);
            current_text.push('\n');

            // Split very large chunks at ~400 words with overlap
            if count_words(&current_text) > 400 {
                let text = current_text.trim().to_string();
                chunks.push((text.clone(), current_header.clone()));
                // Keep last ~20% as overlap
                let words: Vec<&str> = text.split_whitespace().collect();
                let overlap_start = words.len().saturating_sub(80);
                current_text = words[overlap_start..].join(" ");
                current_text.push('\n');
            }
        }
    }

    if !current_text.trim().is_empty() {
        let text = current_text.trim().to_string();
        if count_words(&text) >= 10 {
            chunks.push((text, current_header.clone()));
        }
    }

    chunks
}

fn count_words(s: &str) -> usize {
    s.split_whitespace().count()
}

fn sha2_hex(s: &str) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    s.hash(&mut h);
    format!("{:x}", h.finish())
}

fn sha2_hex_of_chunk(c: &KbChunk) -> String {
    sha2_hex(&c.text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn chunk_markdown_splits_on_headers() {
        let md = "# Section 1\nThis is the first section with enough words to be included in the chunks output.\n# Section 2\nThis is the second section with enough words to also be included in the chunks output.\n";
        let chunks = chunk_markdown(md, "test.md");
        assert!(chunks.len() >= 2);
    }

    #[test]
    fn search_returns_top_k_above_threshold() {
        let dir = tempdir().unwrap();
        let cache = dir.path().join("kb.json");
        let mut kb = KnowledgeBase::new(cache, "test".into());

        // Manually add a chunk with known embedding
        kb.chunks.push(KbChunk {
            text: "test content".into(),
            source_file: "test.md".into(),
            header_context: "Header".into(),
            embedding: vec![1.0, 0.0, 0.0],
        });

        let query = vec![1.0, 0.0, 0.0];
        let results = kb.search(&query, 5, 0.5);
        assert_eq!(results.len(), 1);
        assert!((results[0].score - 1.0).abs() < 1e-4);
    }

    #[test]
    fn search_chunks_finds_similar() {
        let chunks = vec![KbChunk {
            text: "relevant content".into(),
            source_file: "f.md".into(),
            header_context: "".into(),
            embedding: vec![1.0, 0.0, 0.0],
        }];
        let results = search_chunks(&chunks, &[1.0, 0.0, 0.0], 5, 0.5);
        assert_eq!(results.len(), 1);
        assert!((results[0].score - 1.0).abs() < 1e-4);
    }

    #[test]
    fn search_filters_below_threshold() {
        let dir = tempdir().unwrap();
        let cache = dir.path().join("kb.json");
        let mut kb = KnowledgeBase::new(cache, "test".into());
        kb.chunks.push(KbChunk {
            text: "test".into(),
            source_file: "f.md".into(),
            header_context: "".into(),
            embedding: vec![0.0, 1.0, 0.0],
        });
        let query = vec![1.0, 0.0, 0.0]; // orthogonal -> score 0
        let results = kb.search(&query, 5, 0.5);
        assert!(results.is_empty());
    }
}
