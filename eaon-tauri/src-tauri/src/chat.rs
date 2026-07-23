// Chat — streaming and one-shot completions for every provider the app
// talks to. Three wire formats ship (ARCHITECTURE "Wire formats for BYOK"):
// OpenAI-compatible (local Ollama, the hosted Eaon gateway, most BYOK
// endpoints), Anthropic Messages, and Gemini streamGenerateContent. Tokens
// flow back over a Tauri `Channel`; the Free Week trial rides the hosted
// OpenAI path with HMAC-signed headers instead of a key.

/// The pure Anthropic/Gemini request-body builders — a child module (file
/// lives beside this one; lib.rs stays a plain command registry).
#[path = "chat_formats.rs"]
mod formats;

use crate::net;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use tauri::ipc::Channel;

// ---------------------------------------------------------------------------
// Cancellation
// ---------------------------------------------------------------------------

/// Live cancellation flags, keyed by the frontend-chosen request id. Set by
/// `cancel_stream`, checked between chunks by the SSE pump — dropping the
/// reqwest stream aborts the HTTP request, so the model server stops
/// generating too (Ollama honors disconnects).
static CANCEL_FLAGS: LazyLock<Mutex<HashMap<u64, Arc<AtomicBool>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn cancel_flag(id: u64) -> Arc<AtomicBool> {
    CANCEL_FLAGS
        .lock()
        .unwrap()
        .entry(id)
        .or_insert_with(|| Arc::new(AtomicBool::new(false)))
        .clone()
}

fn clear_cancel_flag(id: u64) {
    CANCEL_FLAGS.lock().unwrap().remove(&id);
}

/// Stop an in-flight `chat_stream` — the stop button. Real cancellation:
/// the streaming loop checks this flag per chunk and drops the connection.
#[tauri::command]
pub fn cancel_stream(request_id: u64) {
    cancel_flag(request_id).store(true, Ordering::Relaxed);
}

// ---------------------------------------------------------------------------
// Request / event shapes
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct ChatMessagePayload {
    pub role: String,
    /// A plain string for text-only turns, or an OpenAI content-parts array
    /// (`[{type:"text",…},{type:"image_url",…}]`) for vision turns — passed
    /// to the wire verbatim on the OpenAI path and translated for
    /// Anthropic/Gemini, like the Mac app's `HistoryTurn.openAICompatibleJSON`.
    pub content: serde_json::Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatRequest {
    /// Provider root, e.g. `http://127.0.0.1:11434/v1` for local Ollama.
    /// The per-format path (`/chat/completions`, `/messages`, …) is appended.
    pub base_url: String,
    pub api_key: Option<String>,
    /// Free Week credentials — present only when the hosted gateway is used
    /// without a real key; those requests carry HMAC-signed headers instead.
    pub trial_device: Option<String>,
    pub trial_secret: Option<String>,
    pub model: String,
    pub messages: Vec<ChatMessagePayload>,
    /// Frontend-chosen id used to target `cancel_stream`.
    pub request_id: u64,
    /// User-opted sampling fields (temperature, top_p, max_tokens, …) merged
    /// into the OpenAI body verbatim — absent fields are simply not sent,
    /// which is NOT the same as sending a neutral value (reasoning models
    /// reject temperature outright). Mirrors SamplingParameters.
    #[serde(default)]
    pub sampling: Option<serde_json::Map<String, serde_json::Value>>,
    /// Wire format: "openai" (default when absent), "anthropic", "gemini".
    #[serde(default)]
    pub format: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum StreamEvent {
    Token { text: String },
    Reasoning { text: String },
    Done { cancelled: bool },
    Error { message: String },
}

/// Whether an HTTP error body reads like the server rejecting a sampling
/// field — the cue to retry once without them rather than surfacing a broken
/// chat (mirrors SamplingParameters.looksLikeRejection).
fn looks_like_sampling_rejection(message: &str) -> bool {
    let lower = message.to_lowercase();
    [
        "temperature", "top_p", "top-p", "max_tokens", "max tokens",
        "frequency_penalty", "presence_penalty", "penalty",
        "unsupported value", "unsupported parameter", "unknown parameter",
        "does not support", "not supported", "unexpected parameter",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
}

// ---------------------------------------------------------------------------
// Shared plumbing
// ---------------------------------------------------------------------------

/// Sends the error to the UI channel AND returns it — every failure path
/// both surfaces in the chat and rejects the invoke promise.
fn fail(on_event: &Channel<StreamEvent>, message: String) -> Result<(), String> {
    let _ = on_event.send(StreamEvent::Error { message: message.clone() });
    Err(message)
}

fn connect_error(url: &str, e: &reqwest::Error) -> String {
    if e.is_connect() {
        format!("Couldn't reach the model server at {url}. Is it running? ({e})")
    } else {
        format!("Request failed: {e}")
    }
}

/// Unix seconds now — the trial signature timestamp.
fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or_default()
}

/// Attaches auth for the OpenAI-format paths: a real API key always wins
/// (bearer); otherwise, with Free Week credentials present, sign the exact
/// body bytes the hosted gateway will hash (recipe in trial.rs). Only the
/// hosted gateway speaks the trial, and it is OpenAI-format — the BYOK
/// Anthropic/Gemini paths always carry their own keys.
fn openai_auth(
    builder: reqwest::RequestBuilder,
    request: &ChatRequest,
    body_bytes: &[u8],
) -> reqwest::RequestBuilder {
    if let Some(key) = request.api_key.as_ref().filter(|k| !k.is_empty()) {
        return builder.bearer_auth(key);
    }
    if let (Some(device), Some(secret)) = (
        request.trial_device.as_ref().filter(|d| !d.is_empty()),
        request.trial_secret.as_ref().filter(|s| !s.is_empty()),
    ) {
        let ts = unix_now();
        let sig =
            crate::trial::signature(secret, device, ts, &crate::trial::body_sha256_hex(body_bytes));
        return builder
            .header("X-Eaon-Device", device.as_str())
            .header("X-Eaon-TS", ts.to_string())
            .header("X-Eaon-Sig", sig);
    }
    builder // anonymous is fine for local servers
}

/// A JSON POST whose bytes are serialized exactly once: the trial signature
/// hashes these bytes and the gateway hashes what it receives, so `.json()`'s
/// re-serialization is off the table.
fn openai_post(
    client: &reqwest::Client,
    url: &str,
    request: &ChatRequest,
    body: &serde_json::Value,
) -> reqwest::RequestBuilder {
    let bytes = serde_json::to_vec(body).unwrap_or_default();
    let builder = client
        .post(url)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(bytes.clone());
    openai_auth(builder, request, &bytes)
}

enum LineOutcome {
    Continue,
    Finished,
}

/// Shared SSE pump: buffers network chunks into whole lines (frames split
/// across chunks freely), strips the `data: ` prefix, and hands each payload
/// to the per-format handler. Checks the cancel flag between chunks; a
/// handler returning Finished ends the stream, as does the HTTP stream
/// itself ending (Gemini's only end signal — the others also get a Done then).
async fn pump_sse(
    response: reqwest::Response,
    on_event: &Channel<StreamEvent>,
    cancel: &AtomicBool,
    mut handle_data: impl FnMut(&str) -> LineOutcome,
) -> Result<(), String> {
    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    while let Some(chunk) = stream.next().await {
        if cancel.load(Ordering::Relaxed) {
            let _ = on_event.send(StreamEvent::Done { cancelled: true });
            return Ok(());
        }
        let bytes = match chunk {
            Ok(b) => b,
            Err(e) => return fail(on_event, format!("Stream interrupted: {e}")),
        };
        buffer.push_str(&String::from_utf8_lossy(&bytes));
        while let Some(newline) = buffer.find('\n') {
            let line: String = buffer.drain(..=newline).collect();
            let line = line.trim();
            let Some(data) = line.strip_prefix("data: ") else { continue };
            if let LineOutcome::Finished = handle_data(data) {
                return Ok(());
            }
        }
    }
    let _ = on_event.send(StreamEvent::Done { cancelled: false });
    Ok(())
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn chat_stream(request: ChatRequest, on_event: Channel<StreamEvent>) -> Result<(), String> {
    let flag = cancel_flag(request.request_id);
    let result = match request.format.as_deref() {
        Some("anthropic") => anthropic_stream_inner(&request, &on_event, &flag).await,
        Some("gemini") => gemini_stream_inner(&request, &on_event, &flag).await,
        _ => openai_stream_inner(&request, &on_event, &flag).await,
    };
    clear_cancel_flag(request.request_id);
    result
}

/// A non-streaming completion — one request, the whole answer returned as a
/// string. Used for background work that isn't a live chat: memory
/// extraction and title derivation. Always OpenAI wire format (those jobs
/// run on the hosted gateway or Ollama, both of which speak it), and trial
/// signing applies the same way so Free Week users get memory/titles too.
#[tauri::command]
pub async fn chat_complete(request: ChatRequest) -> Result<String, String> {
    let client = net::http_client(Some(120));
    let url = format!("{}/chat/completions", request.base_url.trim_end_matches('/'));
    let body = serde_json::json!({
        "model": request.model,
        "messages": request.messages.iter()
            .map(|m| serde_json::json!({ "role": m.role, "content": m.content }))
            .collect::<Vec<_>>(),
        "stream": false,
    });
    let resp = net::send_with_retry(openai_post(&client, &url, &request, &body))
        .await
        .map_err(|e| format!("request failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("server returned {}", resp.status()));
    }
    let json: serde_json::Value = resp.json().await.map_err(|e| format!("bad response: {e}"))?;
    Ok(json["choices"][0]["message"]["content"].as_str().unwrap_or("").to_string())
}

// ---------------------------------------------------------------------------
// OpenAI-compatible path (the REF chat_stream_inner, plus retry + trial)
// ---------------------------------------------------------------------------

async fn openai_stream_inner(
    request: &ChatRequest,
    on_event: &Channel<StreamEvent>,
    cancel: &AtomicBool,
) -> Result<(), String> {
    let client = net::http_client(None);
    let url = format!("{}/chat/completions", request.base_url.trim_end_matches('/'));

    let body_with = |sampling: Option<&serde_json::Map<String, serde_json::Value>>| {
        let mut body = serde_json::json!({
            "model": request.model,
            "messages": request.messages.iter()
                .map(|m| serde_json::json!({ "role": m.role, "content": m.content }))
                .collect::<Vec<_>>(),
            "stream": true,
        });
        if let (Some(fields), Some(obj)) = (sampling, body.as_object_mut()) {
            for (key, value) in fields {
                obj.insert(key.clone(), value.clone());
            }
        }
        body
    };

    let sampling = request.sampling.as_ref().filter(|m| !m.is_empty());
    let mut response =
        match net::send_with_retry(openai_post(&client, &url, request, &body_with(sampling))).await
        {
            Ok(r) => r,
            Err(e) => return fail(on_event, connect_error(&url, &e)),
        };

    if !response.status().is_success() {
        let status = response.status();
        let detail = response.text().await.unwrap_or_default();
        // A model that refuses a user-set sampling field (reasoning models
        // and temperature, most commonly) gets one retry without them —
        // costs one request, saves a broken chat.
        let retried = if sampling.is_some() && looks_like_sampling_rejection(&detail) {
            net::send_with_retry(openai_post(&client, &url, request, &body_with(None)))
                .await
                .ok()
                .filter(|r| r.status().is_success())
        } else {
            None
        };
        match retried {
            Some(r) => response = r,
            None => return fail(on_event, format!("Server returned {status}. {detail}")),
        }
    }

    pump_sse(response, on_event, cancel, |data| {
        if data == "[DONE]" {
            let _ = on_event.send(StreamEvent::Done { cancelled: false });
            return LineOutcome::Finished;
        }
        let Ok(json) = serde_json::from_str::<serde_json::Value>(data) else {
            return LineOutcome::Continue;
        };
        let delta = &json["choices"][0]["delta"];
        if let Some(text) = delta.get("content").and_then(|v| v.as_str()) {
            if !text.is_empty() {
                let _ = on_event.send(StreamEvent::Token { text: text.to_string() });
            }
        }
        // Reasoning models (DeepSeek-R1, Nemotron, …) send chain-of-thought
        // as a separate `reasoning`/`reasoning_content` delta field.
        let reasoning = delta
            .get("reasoning")
            .and_then(|v| v.as_str())
            .or_else(|| delta.get("reasoning_content").and_then(|v| v.as_str()));
        if let Some(text) = reasoning {
            if !text.is_empty() {
                let _ = on_event.send(StreamEvent::Reasoning { text: text.to_string() });
            }
        }
        LineOutcome::Continue
    })
    .await
}

// ---------------------------------------------------------------------------
// Anthropic Messages path
// ---------------------------------------------------------------------------

async fn anthropic_stream_inner(
    request: &ChatRequest,
    on_event: &Channel<StreamEvent>,
    cancel: &AtomicBool,
) -> Result<(), String> {
    let client = net::http_client(None);
    let url = format!("{}/messages", request.base_url.trim_end_matches('/'));
    let body =
        formats::build_anthropic_body(&request.model, &request.messages, request.sampling.as_ref());

    let mut builder = client
        .post(&url)
        // Anthropic's pinned API revision — same one the Mac app sends.
        .header("anthropic-version", "2023-06-01")
        .json(&body);
    if let Some(key) = request.api_key.as_ref().filter(|k| !k.is_empty()) {
        builder = builder.header("x-api-key", key.as_str());
    }
    let response = match net::send_with_retry(builder).await {
        Ok(r) => r,
        Err(e) => return fail(on_event, connect_error(&url, &e)),
    };
    if !response.status().is_success() {
        let status = response.status();
        let detail = response.text().await.unwrap_or_default();
        return fail(on_event, format!("Server returned {status}. {detail}"));
    }

    pump_sse(response, on_event, cancel, |data| {
        let Ok(json) = serde_json::from_str::<serde_json::Value>(data) else {
            return LineOutcome::Continue;
        };
        match json["type"].as_str() {
            Some("content_block_delta") => {
                let delta = &json["delta"];
                match delta["type"].as_str() {
                    Some("text_delta") => {
                        if let Some(text) = delta["text"].as_str().filter(|t| !t.is_empty()) {
                            let _ = on_event.send(StreamEvent::Token { text: text.to_string() });
                        }
                    }
                    // Extended thinking streams as its own delta kind — feeds
                    // the UI's reasoning disclosure, same as OpenAI reasoning.
                    Some("thinking_delta") => {
                        if let Some(text) = delta["thinking"].as_str().filter(|t| !t.is_empty()) {
                            let _ =
                                on_event.send(StreamEvent::Reasoning { text: text.to_string() });
                        }
                    }
                    _ => {}
                }
                LineOutcome::Continue
            }
            Some("message_stop") => {
                let _ = on_event.send(StreamEvent::Done { cancelled: false });
                LineOutcome::Finished
            }
            _ => LineOutcome::Continue,
        }
    })
    .await
}

// ---------------------------------------------------------------------------
// Gemini path
// ---------------------------------------------------------------------------

async fn gemini_stream_inner(
    request: &ChatRequest,
    on_event: &Channel<StreamEvent>,
    cancel: &AtomicBool,
) -> Result<(), String> {
    let client = net::http_client(None);
    // Gemini authenticates via a query key, not a header; alt=sse turns its
    // chunked JSON into standard SSE lines. Error messages use the key-less
    // endpoint so the API key never lands in the chat transcript.
    let endpoint = format!(
        "{}/models/{}:streamGenerateContent",
        request.base_url.trim_end_matches('/'),
        request.model
    );
    let url = format!(
        "{endpoint}?alt=sse&key={}",
        request.api_key.clone().unwrap_or_default()
    );
    let body = formats::build_gemini_body(&request.messages, request.sampling.as_ref());

    let response = match net::send_with_retry(client.post(&url).json(&body)).await {
        Ok(r) => r,
        Err(e) => return fail(on_event, connect_error(&endpoint, &e)),
    };
    if !response.status().is_success() {
        let status = response.status();
        let detail = response.text().await.unwrap_or_default();
        return fail(on_event, format!("Server returned {status}. {detail}"));
    }

    // No [DONE]/message_stop equivalent — the HTTP stream ending IS the done
    // signal, which pump_sse emits.
    pump_sse(response, on_event, cancel, |data| {
        let Ok(json) = serde_json::from_str::<serde_json::Value>(data) else {
            return LineOutcome::Continue;
        };
        if let Some(parts) = json["candidates"][0]["content"]["parts"].as_array() {
            for part in parts {
                if let Some(text) = part["text"].as_str().filter(|t| !t.is_empty()) {
                    let _ = on_event.send(StreamEvent::Token { text: text.to_string() });
                }
            }
        }
        LineOutcome::Continue
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    // Ported verbatim from the old lib.rs — the retry heuristic must not
    // drift while moving files.
    #[test]
    fn rejection_matcher_catches_real_provider_errors() {
        // Real shapes seen from OpenAI/compatible servers.
        assert!(looks_like_sampling_rejection(
            r#"{"error":{"message":"Unsupported value: 'temperature' does not support 0.7 with this model."}}"#
        ));
        assert!(looks_like_sampling_rejection("unknown parameter: 'presence_penalty'"));
        assert!(looks_like_sampling_rejection("max_tokens is too large"));
        // Ordinary errors must NOT trigger a silent parameter drop.
        assert!(!looks_like_sampling_rejection("invalid api key"));
        assert!(!looks_like_sampling_rejection("model not found"));
        assert!(!looks_like_sampling_rejection("rate limit exceeded"));
    }

    // The Anthropic/Gemini body-builder tests live with the builders in
    // chat_formats.rs.

    #[test]
    fn trial_signature_is_stable_64_char_hex() {
        let a = crate::trial::signature("s", "d", 1_700_000_000, "abc");
        let b = crate::trial::signature("s", "d", 1_700_000_000, "abc");
        assert_eq!(a, b); // deterministic — the gateway recomputes the same value
        assert_eq!(a.len(), 64);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
