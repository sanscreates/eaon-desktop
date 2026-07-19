// End-to-end smoke test for the streaming path used by `chat_stream` in
// lib.rs: same reqwest client, same rustls TLS, same OpenAI-compatible SSE
// parsing — run against a live local Ollama. Proves the real network + parse
// loop works (the GUI's click-through can't be scripted from CI). Run with:
//   cargo run --example stream_smoke
// Exits non-zero if it can't reach Ollama or gets zero tokens.

use futures_util::StreamExt;

#[tokio::main]
async fn main() {
    let base = "http://127.0.0.1:11434";

    // Pick a real local (non-embedding, non-cloud) model, exactly like the UI's
    // default selection.
    let tags: serde_json::Value = reqwest::get(format!("{base}/api/tags"))
        .await
        .expect("Ollama not reachable")
        .json()
        .await
        .expect("bad /api/tags json");
    let names: Vec<String> = tags["models"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|m| m["name"].as_str().map(str::to_string))
        .collect();
    let model = names
        .iter()
        .find(|n| !n.contains("embed") && !n.contains("cloud"))
        .or_else(|| names.first())
        .expect("no models installed")
        .clone();
    eprintln!("[smoke] streaming from model: {model}");

    let body = serde_json::json!({
        "model": model,
        "messages": [{ "role": "user", "content": "Reply with exactly: streaming works" }],
        "stream": true,
    });

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/completions"))
        .json(&body)
        .send()
        .await
        .expect("request failed");
    assert!(resp.status().is_success(), "server error: {}", resp.status());

    // Verbatim copy of lib.rs's SSE accumulation + parse.
    let mut stream = resp.bytes_stream();
    let mut buffer = String::new();
    let mut tokens = 0usize;
    let mut assembled = String::new();

    'outer: while let Some(chunk) = stream.next().await {
        buffer.push_str(&String::from_utf8_lossy(&chunk.expect("stream error")));
        while let Some(newline) = buffer.find('\n') {
            let line: String = buffer.drain(..=newline).collect();
            let line = line.trim();
            let Some(data) = line.strip_prefix("data: ") else { continue };
            if data == "[DONE]" {
                break 'outer;
            }
            let Ok(json) = serde_json::from_str::<serde_json::Value>(data) else { continue };
            if let Some(text) = json["choices"][0]["delta"]["content"].as_str() {
                if !text.is_empty() {
                    tokens += 1;
                    assembled.push_str(text);
                }
            }
        }
    }

    eprintln!("[smoke] received {tokens} content token(s)");
    eprintln!("[smoke] assembled reply: {assembled:?}");
    assert!(tokens > 0, "FAIL: no content tokens streamed");
    println!("SMOKE PASS: streamed {tokens} tokens from {model}");
}
