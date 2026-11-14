//! MLX Whisper backend (Apple Silicon GPU) via a persistent Python sidecar.
//! The sidecar lives in ~/Library/Application Support/com.meetily.ai/mlx-whisper-runtime (uv-managed venv) and loads
//! the mlx-community/whisper-large-v3-mlx weights from Meetily's models folder.

use anyhow::{anyhow, Result};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

pub const MLX_MODEL_NAME: &str = "large-v3-mlx";
pub const MLX_MODEL_DIRNAME: &str = "mlx-whisper-large-v3";

#[derive(Debug, Deserialize)]
pub struct MlxSegment {
    pub start: f64,
    pub end: f64,
    pub text: String,
    pub avg_logprob: Option<f64>,
    pub no_speech_prob: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct MlxResponse {
    text: Option<String>,
    segments: Option<Vec<MlxSegment>>,
    error: Option<String>,
    ready: Option<bool>,
}

pub struct MlxSidecar {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

fn project_dir() -> PathBuf {
    if let Ok(p) = std::env::var("MEETILY_MLX_PROJECT") {
        return PathBuf::from(p);
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("/"))
        .join("Library/Application Support/com.meetily.ai/mlx-whisper-runtime")
}

/// The MLX model is a directory (config.json + weights.npz/safetensors), not a ggml file.
pub fn mlx_model_ready(dir: &Path) -> bool {
    dir.join("config.json").exists()
        && (dir.join("weights.npz").exists() || dir.join("weights.safetensors").exists())
}

pub fn mlx_model_size_mb(dir: &Path) -> u64 {
    std::fs::read_dir(dir)
        .map(|it| {
            it.filter_map(|e| e.ok())
                .filter_map(|e| e.metadata().ok())
                .map(|m| m.len())
                .sum::<u64>()
                / (1024 * 1024)
        })
        .unwrap_or(0)
}

impl MlxSidecar {
    pub async fn spawn(model_dir: &Path) -> Result<Self> {
        let project = project_dir();
        let python = project.join(".venv/bin/python");
        if !python.exists() {
            return Err(anyhow!(
                "MLX sidecar Python not found at {} (run `uv sync` in {})",
                python.display(),
                project.display()
            ));
        }
        log::info!("Starting MLX Whisper sidecar: {} (model {})", python.display(), model_dir.display());
        let mut child = Command::new(&python)
            .arg("-m")
            .arg("src.meetily_sidecar")
            .current_dir(&project)
            .env("MEETILY_MLX_MODEL", model_dir)
            .env("PYTHONUNBUFFERED", "1")
            .env("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| anyhow!("Failed to start MLX sidecar: {}", e))?;
        let stdin = child.stdin.take().ok_or_else(|| anyhow!("no sidecar stdin"))?;
        let stdout = BufReader::new(child.stdout.take().ok_or_else(|| anyhow!("no sidecar stdout"))?);
        let mut me = Self { child, stdin, stdout };
        let ready = me.read_response().await?;
        if ready.ready != Some(true) {
            return Err(anyhow!("MLX sidecar failed to start: {:?}", ready.error));
        }
        log::info!("MLX Whisper sidecar ready");
        Ok(me)
    }

    async fn read_response(&mut self) -> Result<MlxResponse> {
        let mut line = String::new();
        let n = self.stdout.read_line(&mut line).await?;
        if n == 0 {
            return Err(anyhow!("MLX sidecar exited unexpectedly"));
        }
        Ok(serde_json::from_str(line.trim())?)
    }

    pub async fn transcribe(&mut self, audio: &[f32], language: Option<&str>) -> Result<(String, Vec<MlxSegment>)> {
        let header = serde_json::json!({ "n": audio.len(), "language": language });
        let mut bytes = Vec::with_capacity(audio.len() * 4);
        for s in audio {
            bytes.extend_from_slice(&s.to_le_bytes());
        }
        self.stdin.write_all(format!("{}\n", header).as_bytes()).await?;
        self.stdin.write_all(&bytes).await?;
        self.stdin.flush().await?;
        let resp = self.read_response().await?;
        if let Some(err) = resp.error {
            return Err(anyhow!("MLX transcription failed: {}", err));
        }
        Ok((resp.text.unwrap_or_default(), resp.segments.unwrap_or_default()))
    }

    pub async fn shutdown(mut self) {
        let _ = self.child.kill().await;
    }
}
