//! Native bridge: lets the SwiftUI front-end drive this engine over a Unix socket.
//!
//! Protocol (newline-delimited JSON, both directions):
//!   request  -> {"id": 1, "cmd": "api_get_meetings", "args": {...}}
//!   response <- {"id": 1, "ok": true, "result": <json>}  |  {"id": 1, "ok": false, "error": <json>}
//!   event    <- {"event": "transcript-update", "payload": <json>}
//!
//! Commands are dispatched through Tauri's own IPC pipeline (`Webview::on_message`),
//! so every registered `#[tauri::command]` works unchanged.

use base64::Engine as _;
use std::path::PathBuf;
use std::str::FromStr;
use tauri::ipc::{CallbackFn, InvokeBody, InvokeResponse, InvokeResponseBody};
use tauri::webview::InvokeRequest;
use tauri::{AppHandle, Listener, Manager, Runtime};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::{broadcast, mpsc};

pub const HIDDEN_WEBVIEW_LABEL: &str = "main";

/// Events forwarded to the native UI.
const EVENTS: &[&str] = &[
    "audio-levels", "audio-status", "builtin-ai-download-progress", "chunk-drop-warning",
    "database-initialized", "first-audio-detected", "first-launch-detected",
    "mic-device-switched", "mic-recovery-exhausted", "mic-swap-failed", "mic-unavailable",
    "microphone-recovered", "model-config-updated", "model-download-complete",
    "model-download-error", "model-download-progress", "parakeet-model-download-complete",
    "parakeet-model-download-progress", "recording-error", "recording-paused",
    "recording-resumed", "recording-saved", "recording-started", "recording-starting",
    "recording-startup-progress", "recording-stop-complete", "recording-stopped",
    "request-recording-toggle", "speech-detected", "system-audio-started",
    "system-audio-stopped", "transcript-error", "transcript-update",
    "transcription-complete", "transcription-error", "transcription-progress",
    "transcription-queue-complete", "transcription-started", "transcription-warning",
    "summary-progress", "summary-complete", "summary-error",
    "import-progress", "import-complete", "import-error",
    "retranscription-progress", "retranscription-complete", "retranscription-error",
    "parakeet-model-download-error", "ollama-model-download-progress",
    "ollama-model-download-complete", "ollama-model-download-error",
    "recording-shutdown-progress",
];

pub fn is_headless() -> bool {
    std::env::var("MEETILY_HEADLESS").map(|v| v == "1").unwrap_or(false)
        || std::env::args().any(|a| a == "--headless")
}

pub fn socket_path<R: Runtime>(app: &AppHandle<R>) -> PathBuf {
    if let Ok(p) = std::env::var("MEETILY_ENGINE_SOCKET") {
        return PathBuf::from(p);
    }
    app.path()
        .app_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir())
        .join("engine.sock")
}

/// Exit the engine when the parent (the native app) closes our stdin.
pub fn exit_with_parent<R: Runtime>(app: AppHandle<R>) {
    std::thread::spawn(move || {
        use std::io::Read;
        let mut buf = [0u8; 64];
        let mut stdin = std::io::stdin();
        loop {
            match stdin.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
        }
        log::info!("native bridge: parent closed stdin, exiting engine");
        app.exit(0);
    });
}

pub fn start<R: Runtime>(app: AppHandle<R>) {
    let (event_tx, _) = broadcast::channel::<String>(1024);

    for name in EVENTS {
        let tx = event_tx.clone();
        let name = name.to_string();
        app.listen_any(name.clone(), move |event| {
            let payload = event.payload();
            let payload = if payload.trim().is_empty() { "null" } else { payload };
            let _ = tx.send(format!("{{\"event\":{},\"payload\":{}}}", json_str(&name), payload));
        });
    }

    let path = socket_path(&app);
    tauri::async_runtime::spawn(async move {
        let _ = std::fs::remove_file(&path);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let listener = match UnixListener::bind(&path) {
            Ok(l) => l,
            Err(e) => {
                log::error!("native bridge: failed to bind {:?}: {}", path, e);
                return;
            }
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        log::info!("native bridge: listening on {:?}", path);
        // Signal readiness to the parent on stdout.
        println!("{{\"engine_ready\":true,\"socket\":{}}}", json_str(&path.to_string_lossy()));

        loop {
            let (stream, _) = match listener.accept().await {
                Ok(s) => s,
                Err(e) => {
                    log::error!("native bridge: accept failed: {}", e);
                    continue;
                }
            };
            let app = app.clone();
            let mut events = event_tx.subscribe();
            tauri::async_runtime::spawn(async move {
                let (read_half, mut write_half) = stream.into_split();
                let (out_tx, mut out_rx) = mpsc::unbounded_channel::<String>();

                // Writer: responses + events.
                let writer = tauri::async_runtime::spawn(async move {
                    loop {
                        let line = tokio::select! {
                            Some(l) = out_rx.recv() => l,
                            ev = events.recv() => match ev {
                                Ok(l) => l,
                                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                                Err(_) => break,
                            },
                            else => break,
                        };
                        if write_half.write_all(line.as_bytes()).await.is_err()
                            || write_half.write_all(b"\n").await.is_err()
                        {
                            break;
                        }
                    }
                });

                let mut lines = BufReader::new(read_half).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if line.trim().is_empty() {
                        continue;
                    }
                    dispatch(&app, &line, out_tx.clone());
                }
                writer.abort();
            });
        }
    });
}

fn dispatch<R: Runtime>(app: &AppHandle<R>, line: &str, out: mpsc::UnboundedSender<String>) {
    let req: serde_json::Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => {
            let _ = out.send(format!("{{\"id\":null,\"ok\":false,\"error\":{}}}", json_str(&e.to_string())));
            return;
        }
    };
    let id = req.get("id").cloned().unwrap_or(serde_json::Value::Null).to_string();
    let cmd = req.get("cmd").and_then(|c| c.as_str()).unwrap_or_default().to_string();
    let args = req.get("args").cloned().unwrap_or_else(|| serde_json::json!({}));

    let Some(webview) = app
        .get_webview_window(HIDDEN_WEBVIEW_LABEL)
        .map(|w| AsRef::<tauri::Webview<R>>::as_ref(&w).clone())
    else {
        let _ = out.send(format!("{{\"id\":{},\"ok\":false,\"error\":\"engine webview missing\"}}", id));
        return;
    };

    let request = InvokeRequest {
        cmd,
        callback: CallbackFn(0),
        error: CallbackFn(1),
        url: tauri::Url::from_str("tauri://localhost").unwrap(),
        body: InvokeBody::Json(args),
        headers: Default::default(),
        invoke_key: app.invoke_key().to_string(),
    };

    let app2 = app.clone();
    let _ = app2.run_on_main_thread(move || {
        webview.on_message(
            request,
            Box::new(move |_webview, _cmd, response, _cb, _err| {
                let line = match response {
                    InvokeResponse::Ok(InvokeResponseBody::Json(s)) => {
                        let s = if s.trim().is_empty() { "null".to_string() } else { s };
                        format!("{{\"id\":{},\"ok\":true,\"result\":{}}}", id, s)
                    }
                    InvokeResponse::Ok(InvokeResponseBody::Raw(bytes)) => format!(
                        "{{\"id\":{},\"ok\":true,\"result\":{{\"base64\":{}}}}}",
                        id,
                        json_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
                    ),
                    InvokeResponse::Err(e) => format!("{{\"id\":{},\"ok\":false,\"error\":{}}}", id, e.0),
                };
                let _ = out.send(line);
            }),
        );
    });
}

fn json_str(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
}
