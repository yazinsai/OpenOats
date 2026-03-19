use std::path::{Path, PathBuf};

const MODEL_URL: &str =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";

pub fn model_exists(path: &Path) -> bool {
    path.exists()
}

/// Download the Whisper model to `dest`, emitting progress via `on_progress(pct: u32)`.
/// Uses a `.tmp` file then renames atomically on completion.
pub async fn download_model<F>(dest: PathBuf, on_progress: F) -> Result<(), String>
where
    F: Fn(u32) + Send + 'static,
{
    use reqwest::Client;
    use tokio::io::AsyncWriteExt;

    if dest.exists() {
        return Ok(());
    }

    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }

    let client = Client::new();
    let resp = client.get(MODEL_URL).send().await.map_err(|e| e.to_string())?;

    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }

    let total = resp.content_length().unwrap_or(0);
    let mut stream = resp.bytes_stream();
    let tmp = dest.with_extension("tmp");
    let mut file = tokio::fs::File::create(&tmp).await.map_err(|e| e.to_string())?;

    let mut downloaded: u64 = 0;
    use futures::StreamExt;
    while let Some(chunk) = stream.next().await {
        let bytes = chunk.map_err(|e| e.to_string())?;
        file.write_all(&bytes).await.map_err(|e| e.to_string())?;
        downloaded += bytes.len() as u64;
        if total > 0 {
            on_progress((downloaded * 100 / total) as u32);
        }
    }

    file.flush().await.map_err(|e| e.to_string())?;
    drop(file);
    std::fs::rename(&tmp, &dest).map_err(|e| e.to_string())?;
    log::info!("Model downloaded to {}", dest.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn model_exists_check_returns_false_for_missing() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("ggml-base.en.bin");
        assert!(!model_exists(&path));
    }

    #[test]
    fn model_exists_check_returns_true_when_present() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("ggml-base.en.bin");
        std::fs::write(&path, b"fake model").unwrap();
        assert!(model_exists(&path));
    }
}
