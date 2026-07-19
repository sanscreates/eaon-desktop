// Eaon's Rust core. All network I/O and disk persistence live here, not in
// the webview: the frontend calls these commands, and streamed tokens come
// back over Tauri `Channel`s. One OpenAI-compatible chat path serves local
// Ollama, Aqua's hosted API, and any BYOK endpoint alike.

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use tauri::ipc::Channel;
use tauri::Manager;

/// Agent mode's coding tools (write/edit/read/run/search/…) — the
/// cross-platform port of the Mac app's DesktopControlService.
mod tools;

/// The Local API Server — a loopback OpenAI-compatible endpoint other tools
/// can point at, proxying to the user's configured providers.
mod server;

/// MCP plugins — connect to Model Context Protocol servers (remote HTTP or
/// local stdio) and expose their tools to chats.
mod mcp;

// ---------------------------------------------------------------------------
// Chat streaming (cancellable)
// ---------------------------------------------------------------------------

/// Live cancellation flags, keyed by the frontend-chosen request id. Set by
/// `cancel_stream`, checked between chunks by `chat_stream` — dropping the
/// reqwest stream aborts the HTTP request, so the model server stops
/// generating too (Ollama honors disconnects).
static CANCEL_FLAGS: LazyLock<Mutex<HashMap<u64, Arc<AtomicBool>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

// ---------------------------------------------------------------------------
// Outbound HTTP — one place to build clients so the user's optional proxy
// (Settings → General → Network) applies to ALL provider/search/image
// traffic, the AppHTTP/ProxyStore pattern from macOS. Off by default, in
// which case clients behave exactly as before.
// ---------------------------------------------------------------------------

static PROXY_URL: LazyLock<Mutex<Option<String>>> = LazyLock::new(|| Mutex::new(None));

/// Sets (or clears, with None/empty) the proxy every subsequent outbound
/// client routes through. Returns an error for an unparseable proxy URL so
/// the UI can say so instead of silently sending traffic direct.
#[tauri::command]
fn set_proxy(url: Option<String>) -> Result<(), String> {
    let cleaned = url.map(|u| u.trim().to_string()).filter(|u| !u.is_empty());
    if let Some(u) = cleaned.as_ref() {
        reqwest::Proxy::all(u.clone()).map_err(|e| format!("That proxy address doesn't parse: {e}"))?;
    }
    *PROXY_URL.lock().unwrap() = cleaned;
    Ok(())
}

/// A reqwest client honoring the configured proxy. `timeout_secs: None`
/// leaves streaming responses unbounded (a chat stream can legitimately run
/// minutes); requests with a natural bound pass one.
fn http_client(timeout_secs: Option<u64>) -> reqwest::Client {
    let mut builder = reqwest::Client::builder();
    if let Some(secs) = timeout_secs {
        builder = builder.timeout(std::time::Duration::from_secs(secs));
    }
    if let Some(proxy_url) = PROXY_URL.lock().unwrap().clone() {
        if let Ok(proxy) = reqwest::Proxy::all(proxy_url) {
            builder = builder.proxy(proxy);
        }
    }
    builder.build().unwrap_or_default()
}

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

#[derive(Deserialize)]
struct ChatMessagePayload {
    role: String,
    /// A plain string for text-only turns, or an OpenAI content-parts array
    /// (`[{type:"text",...},{type:"image_url",...}]`) for vision turns —
    /// passed through to the wire verbatim either way, exactly like the Mac
    /// app's `HistoryTurn.openAICompatibleJSON`.
    content: serde_json::Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatRequest {
    /// OpenAI-compatible base, e.g. `http://127.0.0.1:11434/v1` for local
    /// Ollama or `https://api.aquadevs.com/v1`. `/chat/completions` appended.
    base_url: String,
    api_key: Option<String>,
    model: String,
    messages: Vec<ChatMessagePayload>,
    /// Frontend-chosen id used to target `cancel_stream`.
    request_id: u64,
    /// User-opted sampling fields (temperature, top_p, max_tokens, …) merged
    /// into the request body verbatim — absent fields are simply not sent,
    /// which is NOT the same as sending a neutral value (reasoning models
    /// reject temperature outright). Mirrors SamplingParameters.
    #[serde(default)]
    sampling: Option<serde_json::Map<String, serde_json::Value>>,
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

#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum StreamEvent {
    Token { text: String },
    Reasoning { text: String },
    Done { cancelled: bool },
    Error { message: String },
}

#[tauri::command]
async fn chat_stream(request: ChatRequest, on_event: Channel<StreamEvent>) -> Result<(), String> {
    let flag = cancel_flag(request.request_id);
    let result = chat_stream_inner(&request, &on_event, &flag).await;
    clear_cancel_flag(request.request_id);
    result
}

async fn chat_stream_inner(
    request: &ChatRequest,
    on_event: &Channel<StreamEvent>,
    cancel: &AtomicBool,
) -> Result<(), String> {
    let client = http_client(None);
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

    let send_once = |body: serde_json::Value| {
        let client = client.clone();
        let url = url.clone();
        let api_key = request.api_key.clone();
        async move {
            let mut builder = client.post(&url).json(&body);
            if let Some(key) = api_key.as_ref().filter(|k| !k.is_empty()) {
                builder = builder.bearer_auth(key);
            }
            builder.send().await
        }
    };

    let sampling = request.sampling.as_ref().filter(|m| !m.is_empty());
    let mut response = match send_once(body_with(sampling)).await {
        Ok(r) => r,
        Err(e) => {
            let message = if e.is_connect() {
                format!("Couldn't reach the model server at {url}. Is it running? ({e})")
            } else {
                format!("Request failed: {e}")
            };
            let _ = on_event.send(StreamEvent::Error { message: message.clone() });
            return Err(message);
        }
    };

    if !response.status().is_success() {
        let status = response.status();
        let detail = response.text().await.unwrap_or_default();
        // A model that refuses a user-set sampling field (reasoning models
        // and temperature, most commonly) gets one retry without them —
        // costs one request, saves a broken chat.
        if sampling.is_some() && looks_like_sampling_rejection(&detail) {
            match send_once(body_with(None)).await {
                Ok(retry) if retry.status().is_success() => response = retry,
                _ => {
                    let message = format!("Server returned {status}. {detail}");
                    let _ = on_event.send(StreamEvent::Error { message: message.clone() });
                    return Err(message);
                }
            }
        } else {
            let message = format!("Server returned {status}. {detail}");
            let _ = on_event.send(StreamEvent::Error { message: message.clone() });
            return Err(message);
        }
    }

    // SSE frames can split across network chunks — accumulate, parse whole lines.
    let mut stream = response.bytes_stream();
    let mut buffer = String::new();

    while let Some(chunk) = stream.next().await {
        if cancel.load(Ordering::Relaxed) {
            let _ = on_event.send(StreamEvent::Done { cancelled: true });
            return Ok(());
        }
        let bytes = match chunk {
            Ok(b) => b,
            Err(e) => {
                let message = format!("Stream interrupted: {e}");
                let _ = on_event.send(StreamEvent::Error { message: message.clone() });
                return Err(message);
            }
        };
        buffer.push_str(&String::from_utf8_lossy(&bytes));

        while let Some(newline) = buffer.find('\n') {
            let line: String = buffer.drain(..=newline).collect();
            let line = line.trim();
            let Some(data) = line.strip_prefix("data: ") else { continue };
            if data == "[DONE]" {
                let _ = on_event.send(StreamEvent::Done { cancelled: false });
                return Ok(());
            }
            let Ok(json) = serde_json::from_str::<serde_json::Value>(data) else { continue };
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
        }
    }

    let _ = on_event.send(StreamEvent::Done { cancelled: false });
    Ok(())
}

/// Stop an in-flight `chat_stream` — the stop button. Real cancellation:
/// the streaming loop checks this flag per chunk and drops the connection.
#[tauri::command]
fn cancel_stream(request_id: u64) {
    cancel_flag(request_id).store(true, Ordering::Relaxed);
}

/// A non-streaming completion — one request, the whole answer returned as a
/// string. Used for background work that isn't a live chat: memory
/// extraction (silently mining durable facts from an exchange). Same
/// OpenAI-compatible wire format as `chat_stream`, just `stream: false`.
#[tauri::command]
async fn chat_complete(request: ChatRequest) -> Result<String, String> {
    let client = http_client(Some(120));
    let url = format!("{}/chat/completions", request.base_url.trim_end_matches('/'));
    let body = serde_json::json!({
        "model": request.model,
        "messages": request.messages.iter()
            .map(|m| serde_json::json!({ "role": m.role, "content": m.content }))
            .collect::<Vec<_>>(),
        "stream": false,
    });
    let mut builder = client.post(&url).json(&body);
    if let Some(key) = request.api_key.as_ref().filter(|k| !k.is_empty()) {
        builder = builder.bearer_auth(key);
    }
    let resp = builder.send().await.map_err(|e| format!("request failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("server returned {}", resp.status()));
    }
    let json: serde_json::Value = resp.json().await.map_err(|e| format!("bad response: {e}"))?;
    Ok(json["choices"][0]["message"]["content"].as_str().unwrap_or("").to_string())
}

// ---------------------------------------------------------------------------
// Ollama management
// ---------------------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OllamaModelInfo {
    name: String,
    size_bytes: u64,
    param_size: Option<String>,
    quantization: Option<String>,
    family: Option<String>,
    /// Ollama's real capability tags ("completion", "vision", "image",
    /// "thinking", …) — how diffusion models are told apart from chat ones.
    capabilities: Option<Vec<String>>,
}

/// Detailed installed-model list from `/api/tags` — name, on-disk size, and
/// the real spec fields Ollama reports (mirrors the Mac app's Models page).
#[tauri::command]
async fn ollama_tags(base_url: String) -> Result<Vec<OllamaModelInfo>, String> {
    let url = format!("{}/api/tags", base_url.trim_end_matches('/'));
    let response = http_client(Some(10))
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Couldn't reach Ollama at {url}. Is it installed and running? ({e})"))?;
    let json: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
    let models = json["models"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let name = m["name"].as_str()?.to_string();
                    Some(OllamaModelInfo {
                        name,
                        size_bytes: m["size"].as_u64().unwrap_or(0),
                        param_size: m["details"]["parameter_size"].as_str().map(str::to_string),
                        quantization: m["details"]["quantization_level"].as_str().map(str::to_string),
                        family: m["details"]["family"].as_str().map(str::to_string),
                        capabilities: m["capabilities"].as_array().map(|caps| {
                            caps.iter().filter_map(|c| c.as_str().map(str::to_string)).collect()
                        }),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(models)
}

#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum PullEvent {
    Progress { status: String, completed: u64, total: u64 },
    Done,
    Error { message: String },
}

/// Downloads a model through Ollama's own `/api/pull`, streaming NDJSON
/// progress lines back as real completed/total byte counts.
#[tauri::command]
async fn ollama_pull(base_url: String, model: String, on_event: Channel<PullEvent>) -> Result<(), String> {
    let url = format!("{}/api/pull", base_url.trim_end_matches('/'));
    let client = http_client(None);
    let response = client
        .post(&url)
        .json(&serde_json::json!({ "model": model, "stream": true }))
        .send()
        .await
        .map_err(|e| {
            let message = format!("Couldn't reach Ollama: {e}");
            let _ = on_event.send(PullEvent::Error { message: message.clone() });
            message
        })?;

    if !response.status().is_success() {
        let message = format!("Ollama returned {}", response.status());
        let _ = on_event.send(PullEvent::Error { message: message.clone() });
        return Err(message);
    }

    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    while let Some(chunk) = stream.next().await {
        let bytes = chunk.map_err(|e| {
            let message = format!("Download interrupted: {e}");
            let _ = on_event.send(PullEvent::Error { message: message.clone() });
            message
        })?;
        buffer.push_str(&String::from_utf8_lossy(&bytes));
        while let Some(newline) = buffer.find('\n') {
            let line: String = buffer.drain(..=newline).collect();
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let Ok(json) = serde_json::from_str::<serde_json::Value>(line) else { continue };
            if let Some(err) = json["error"].as_str() {
                let message = err.to_string();
                let _ = on_event.send(PullEvent::Error { message: message.clone() });
                return Err(message);
            }
            let status = json["status"].as_str().unwrap_or("").to_string();
            let completed = json["completed"].as_u64().unwrap_or(0);
            let total = json["total"].as_u64().unwrap_or(0);
            let _ = on_event.send(PullEvent::Progress { status, completed, total });
        }
    }
    let _ = on_event.send(PullEvent::Done);
    Ok(())
}

/// Deletes a model AND verifies it's actually gone afterward (re-checks the
/// tags list) — returns an error message instead of pretending success, the
/// same says-deleted-but-storage-unchanged guard the Mac app has.
#[tauri::command]
async fn ollama_delete(base_url: String, model: String) -> Result<(), String> {
    let base = base_url.trim_end_matches('/').to_string();
    let client = http_client(Some(30));
    let response = client
        .delete(format!("{base}/api/delete"))
        .json(&serde_json::json!({ "model": model }))
        .send()
        .await
        .map_err(|e| format!("Couldn't reach Ollama: {e}"))?;

    if !response.status().is_success() {
        let detail = response.text().await.unwrap_or_default();
        return Err(format!("Ollama refused to delete {model}: {detail}"));
    }

    // Verify: even on 200, confirm the model is really gone.
    let tags: serde_json::Value = client
        .get(format!("{base}/api/tags"))
        .send()
        .await
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())?;
    let still_there = tags["models"]
        .as_array()
        .map(|arr| arr.iter().any(|m| m["name"].as_str() == Some(model.as_str())))
        .unwrap_or(false);
    if still_there {
        return Err(format!("Ollama reported success but {model} is still installed — nothing was freed."));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Provider model listing (Aqua / BYOK)
// ---------------------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProviderModel {
    id: String,
    name: Option<String>,
    model_type: Option<String>,
    tier: Option<String>,
}

/// GET `{base}/models` (OpenAI-compatible shape `{data: [{id, ...}]}`).
#[tauri::command]
async fn fetch_provider_models(base_url: String, api_key: Option<String>) -> Result<Vec<ProviderModel>, String> {
    let url = format!("{}/models", base_url.trim_end_matches('/'));
    let client = http_client(Some(30));
    let mut builder = client.get(&url);
    if let Some(key) = api_key.filter(|k| !k.is_empty()) {
        builder = builder.bearer_auth(key);
    }
    let response = builder.send().await.map_err(|e| format!("Couldn't reach {url}: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("Server returned {} for {url}", response.status()));
    }
    let json: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
    let models = json["data"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    Some(ProviderModel {
                        id: m["id"].as_str()?.to_string(),
                        name: m["name"].as_str().map(str::to_string),
                        model_type: m["type"].as_str().map(str::to_string),
                        tier: m["tier"].as_str().map(str::to_string),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(models)
}

// ---------------------------------------------------------------------------
// Skills — SKILL.md installs from GitHub, and importing from this PC's own
// Claude Code skills folder. Parsing (frontmatter + normalizeName) lives in
// TS (`skills.ts`), shared with the Mac-mirrored starter skills; these two
// commands only do the I/O the webview's CSP wouldn't allow directly.
// ---------------------------------------------------------------------------

/// Fetches a URL as plain text — used for GitHub-hosted SKILL.md files.
/// Generic on purpose (any candidate raw.githubusercontent.com URL), not
/// specific to skills, but kept here since skills are its only caller.
#[tauri::command]
async fn fetch_text_url(url: String) -> Result<String, String> {
    let response = http_client(Some(30))
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Couldn't reach {url}: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("{} for {url}", response.status()));
    }
    response.text().await.map_err(|e| e.to_string())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeSkillCandidate {
    path: String,
    text: String,
}

/// Every `SKILL.md` under `~/.claude/skills/<folder>/` on this PC — feeds
/// the "Import from Claude Code" picker. Frontmatter parsing, existing-name
/// dedup, and skipping anything that fails to parse all happen in TS
/// (`SkillStore`-equivalent state), same as the Mac app's own
/// `localClaudeSkillCandidates`.
#[tauri::command]
fn scan_claude_skills(app: tauri::AppHandle) -> Vec<ClaudeSkillCandidate> {
    let Ok(home) = app.path().home_dir() else { return Vec::new() };
    let base = home.join(".claude").join("skills");
    let Ok(entries) = std::fs::read_dir(&base) else { return Vec::new() };

    let mut candidates = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let skill_file = path.join("SKILL.md");
        if let Ok(text) = std::fs::read_to_string(&skill_file) {
            candidates.push(ClaudeSkillCandidate { path: skill_file.to_string_lossy().into_owned(), text });
        }
    }
    candidates.sort_by(|a, b| a.path.cmp(&b.path));
    candidates
}

// ---------------------------------------------------------------------------
// Web search — the Mac app's WebSearchService: MIKLIUM's free, keyless
// Search API (github.com/MIKLIUM-Team/MIKLIUM). Short search-engine
// snippets only (maxLargeSnippets: 0) so a mid-conversation search stays
// fast instead of scraping full pages.
// ---------------------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WebSearchHit {
    url: String,
    snippet: String,
}

#[tauri::command]
async fn web_search(query: String) -> Result<Vec<WebSearchHit>, String> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Err("Empty search query.".to_string());
    }
    let client = http_client(Some(25));
    let body = serde_json::json!({
        "search": [trimmed],
        "type": "default",
        "maxSmallSnippets": 8,
        "maxLargeSnippets": 0,
    });
    let resp = client
        .post("https://miklium.vercel.app/api/search")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Search failed: {e}"))?;
    // MIKLIUM reports failure (including zero results) via a 4xx status but
    // always with the same {success, error} JSON body — `success` alone is
    // the branch, matching the Mac implementation.
    let json: serde_json::Value = resp
        .json()
        .await
        .map_err(|_| "The search service returned an unexpected response.".to_string())?;
    if json["success"].as_bool() != Some(true) {
        return Err(json["error"].as_str().unwrap_or("No results found.").to_string());
    }
    let results = json["results"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|entry| {
                    Some(WebSearchHit {
                        url: entry["url"].as_str()?.to_string(),
                        snippet: entry["snippet"].as_str()?.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(results)
}

// ---------------------------------------------------------------------------
// Image generation — one command speaking every wire shape the Mac app's
// ImageGeneration.swift speaks: OpenAI-compatible `/images/generations`
// (b64_json, URL fallback), Automatic1111's `/sdapi/v1/txt2img` (DrawThings/
// ComfyUI-compatible), Ollama's `/api/generate` (its diffusion models), and
// Aqua's own `{url}` shape. Returns base64 bytes + a suggested file name;
// the frontend stores it through the same attachments path as user uploads.
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImageGenRequest {
    /// "openai" | "automatic1111" | "ollama" | "aqua"
    format: String,
    base_url: String,
    model: String,
    prompt: String,
    api_key: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ImageGenResult {
    data_base64: String,
    suggested_file_name: String,
}

fn suggested_image_name(prefix: &str) -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}-{}.png", sanitize_file_name(prefix), secs)
}

async fn fetch_image_url(client: &reqwest::Client, url: &str) -> Result<Vec<u8>, String> {
    let resp = client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("couldn't fetch the generated image: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("couldn't fetch the generated image ({})", resp.status()));
    }
    resp.bytes().await.map(|b| b.to_vec()).map_err(|e| e.to_string())
}

#[tauri::command]
async fn generate_image(request: ImageGenRequest) -> Result<ImageGenResult, String> {
    use base64::Engine as _;
    let b64 = &base64::engine::general_purpose::STANDARD;
    // Local diffusion on CPU can genuinely take minutes — same generous
    // allowance as the Mac app's local paths; cloud calls finish long before.
    let client = http_client(Some(300));
    let base = request.base_url.trim_end_matches('/');

    let (url, body): (String, serde_json::Value) = match request.format.as_str() {
        "openai" => (
            format!("{base}/images/generations"),
            serde_json::json!({ "model": request.model, "prompt": request.prompt, "response_format": "b64_json" }),
        ),
        "automatic1111" => (
            format!("{base}/sdapi/v1/txt2img"),
            serde_json::json!({ "prompt": request.prompt }),
        ),
        "ollama" => (
            format!("{base}/api/generate"),
            serde_json::json!({ "model": request.model, "prompt": request.prompt, "stream": false }),
        ),
        "aqua" => (
            format!("{base}/images/generations"),
            serde_json::json!({ "model": request.model, "prompt": request.prompt }),
        ),
        other => return Err(format!("unknown image format: {other}")),
    };

    let mut builder = client.post(&url).json(&body);
    if let Some(key) = request.api_key.as_ref().filter(|k| !k.is_empty()) {
        builder = builder.bearer_auth(key);
    }
    let resp = builder
        .send()
        .await
        .map_err(|e| {
            if e.is_connect() {
                format!("Couldn't reach the image server at {url}. Is it running? ({e})")
            } else {
                format!("Image request failed: {e}")
            }
        })?;
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        let detail = if text.is_empty() { "no further detail from the server.".to_string() } else { text };
        return Err(format!("Image generation failed ({status}): {detail}"));
    }
    let json: serde_json::Value =
        serde_json::from_str(&text).map_err(|_| "The server responded, but didn't include an image.".to_string())?;

    let no_image = || "The server responded, but didn't include an image.".to_string();
    let bytes: Vec<u8> = match request.format.as_str() {
        "openai" => {
            let first = json["data"][0].clone();
            if let Some(encoded) = first["b64_json"].as_str() {
                b64.decode(encoded).map_err(|_| no_image())?
            } else if let Some(image_url) = first["url"].as_str() {
                // A provider that ignores response_format and sends a URL
                // anyway — fall back rather than failing outright.
                fetch_image_url(&client, image_url).await?
            } else {
                return Err(no_image());
            }
        }
        "automatic1111" => {
            let encoded = json["images"][0].as_str().ok_or_else(no_image)?;
            b64.decode(encoded).map_err(|_| no_image())?
        }
        "ollama" => {
            let encoded = json["image"].as_str().ok_or_else(no_image)?;
            b64.decode(encoded).map_err(|_| no_image())?
        }
        "aqua" => {
            let image_url = json["url"].as_str().ok_or_else(no_image)?;
            fetch_image_url(&client, image_url).await?
        }
        _ => unreachable!(),
    };

    Ok(ImageGenResult {
        data_base64: b64.encode(bytes),
        suggested_file_name: suggested_image_name(if request.model.is_empty() { "image" } else { &request.model }),
    })
}

// ---------------------------------------------------------------------------
// Attachments — files/images the user attaches to a message, stored under
// the app data dir exactly like the Mac app's AttachmentStore (a UUID-ish
// prefixed copy, referenced from the message by stored name only, so the
// conversation JSON never carries megabytes of base64).
// ---------------------------------------------------------------------------

fn attachments_dir(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("attachments");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

/// Keeps a user-supplied filename safe to embed in a stored name: path
/// separators and anything exotic dropped, `..` sequences eliminated (so the
/// name always passes `validated_stored_name` on the way back out), never
/// empty.
fn sanitize_file_name(name: &str) -> String {
    let mut cleaned: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') {
                c
            } else {
                '-'
            }
        })
        .collect();
    while cleaned.contains("..") {
        cleaned = cleaned.replace("..", "-");
    }
    let trimmed = cleaned.trim_matches(['.', ' ', '-']).to_string();
    if trimmed.is_empty() { "file".to_string() } else { trimmed }
}

/// A stored name must be exactly one path component we generated — anything
/// with separators or `..` is refused before touching the filesystem.
fn validated_stored_name(name: &str) -> Result<&str, String> {
    if name.is_empty()
        || name.contains('/')
        || name.contains('\\')
        || name.contains("..")
        || name.starts_with('.')
    {
        return Err("invalid attachment name".to_string());
    }
    Ok(name)
}

/// Saves attachment bytes (base64 from the webview) under the attachments
/// dir and returns the stored file name the message should reference.
#[tauri::command]
fn save_attachment(app: tauri::AppHandle, data_base64: String, file_name: String) -> Result<String, String> {
    use base64::Engine as _;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data_base64.as_bytes())
        .map_err(|e| format!("bad attachment data: {e}"))?;
    // 50 MB cap — same ballpark guard as every provider's own payload limit;
    // stops a mis-picked video from silently eating the data dir.
    if bytes.len() > 50 * 1024 * 1024 {
        return Err("attachment is too large (over 50 MB)".to_string());
    }
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let stored = format!("{}-{}", nanos, sanitize_file_name(&file_name));
    let path = attachments_dir(&app)?.join(&stored);
    std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
    Ok(stored)
}

/// Reads a stored attachment back as base64 — for thumbnails and for
/// building vision payloads at send time.
#[tauri::command]
fn read_attachment(app: tauri::AppHandle, stored_file_name: String) -> Result<String, String> {
    use base64::Engine as _;
    let name = validated_stored_name(&stored_file_name)?;
    let path = attachments_dir(&app)?.join(name);
    let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
    Ok(base64::engine::general_purpose::STANDARD.encode(bytes))
}

#[cfg(test)]
mod sampling_tests {
    use super::looks_like_sampling_rejection;

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
}

#[cfg(test)]
mod attachment_tests {
    use super::{sanitize_file_name, validated_stored_name};

    #[test]
    fn sanitize_strips_separators_and_traversal() {
        // Every sanitized name must survive the read-side validation — the
        // exact cosmetic result matters less than that invariant.
        for hostile in ["../../etc/passwd", "a/b\\c.png", "....", "..\\..\\x", ""] {
            let cleaned = sanitize_file_name(hostile);
            assert!(!cleaned.is_empty());
            let stored = format!("12345-{cleaned}");
            assert!(validated_stored_name(&stored).is_ok(), "{hostile:?} -> {stored:?}");
        }
        assert_eq!(sanitize_file_name("photo (1).png"), "photo -1-.png");
        assert_eq!(sanitize_file_name("report.pdf"), "report.pdf");
    }

    #[test]
    fn stored_name_validation_refuses_escapes() {
        assert!(validated_stored_name("123-photo.png").is_ok());
        assert!(validated_stored_name("../state.json").is_err());
        assert!(validated_stored_name("a/b.png").is_err());
        assert!(validated_stored_name("a\\b.png").is_err());
        assert!(validated_stored_name(".hidden").is_err());
        assert!(validated_stored_name("").is_err());
    }
}

// ---------------------------------------------------------------------------
// Persistence — one JSON blob in the app data dir (the UserDefaults
// equivalent the Mac app uses; same single-source-of-truth shape).
// ---------------------------------------------------------------------------

fn state_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("state.json"))
}

#[tauri::command]
fn load_app_state(app: tauri::AppHandle) -> Result<String, String> {
    let path = state_path(&app)?;
    if !path.exists() {
        return Ok(String::new());
    }
    std::fs::read_to_string(&path).map_err(|e| e.to_string())
}

/// Atomic write (temp file + rename) so a crash mid-save can never corrupt
/// the whole conversation history.
#[tauri::command]
fn save_app_state(app: tauri::AppHandle, json: String) -> Result<(), String> {
    let path = state_path(&app)?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            chat_stream,
            chat_complete,
            cancel_stream,
            ollama_tags,
            ollama_pull,
            ollama_delete,
            fetch_provider_models,
            fetch_text_url,
            scan_claude_skills,
            set_proxy,
            web_search,
            generate_image,
            save_attachment,
            read_attachment,
            load_app_state,
            save_app_state,
            tools::run_agent_tool,
            mcp::mcp_connect,
            mcp::mcp_call,
            mcp::mcp_disconnect,
            server::start_local_server,
            server::stop_local_server,
            server::local_server_running
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
