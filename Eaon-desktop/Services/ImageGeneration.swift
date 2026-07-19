import Foundation

/// A generated image's raw result — bytes plus a suggested file name. Every
/// provider path (Aqua, BYOK cloud, local server) normalizes to this one
/// shape before it ever reaches `AttachmentStore`, regardless of whether the
/// wire response carried a URL to fetch or the bytes already inline as
/// base64.
struct GeneratedImageResult {
    let data: Data
    let suggestedFileName: String
}

enum ImageGenerationError: LocalizedError {
    case httpError(status: Int, message: String)
    case noImageInResponse
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let message):
            return "Image generation failed (\(status)): \(message.isEmpty ? "no further detail from the server." : message)"
        case .noImageInResponse:
            return "The server responded, but didn't include an image."
        case .invalidEndpoint:
            return "That address doesn't look like a valid URL."
        }
    }
}

private func timestampedFileName(prefix: String) -> String {
    "\(prefix)-\(Int(Date().timeIntervalSince1970)).png"
}

// MARK: - Aqua's hosted image models

/// Aqua's hosted image-generation models — same account, same API key as
/// chat, zero extra setup. `AquaSupportedModels` is a hand-maintained
/// chat-only allowlist that silently excludes every non-text model; this
/// reads the live `type` field instead, so a new image model Aqua adds
/// later shows up automatically rather than needing another code change.
enum AquaImageModels {
    static func fetchAvailable() async -> [APIModel] {
        guard let (data, response) = try? await AppHTTP.session.data(from: AquaAPI.modelsURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(APIModelResponse.self, from: data) else { return [] }
        return decoded.data.filter { ($0.type ?? "").lowercased() == "image" }
    }

    /// Verified live during development: `POST /v1/images/generations` with
    /// `{model, prompt}` returns Aqua's own `{success, model, url, latency}`
    /// shape — NOT the OpenAI `data[]` array shape, despite chat completions
    /// being OpenAI-compatible. A real call against `nanobanana` returned a
    /// genuine, fetchable 1024×1024 PNG.
    static func generate(model: String, prompt: String, apiKey: String) async throws -> GeneratedImageResult {
        var request = URLRequest(url: AquaAPI.baseURL.appendingPathComponent("images/generations"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt])

        let (data, response) = try await TransientHTTPRetry.sendData(request)
        guard response.statusCode == 200 else {
            throw ImageGenerationError.httpError(status: response.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["url"] as? String,
              let imageURL = URL(string: urlString) else {
            throw ImageGenerationError.noImageInResponse
        }
        let (imageData, imageResponse) = try await AppHTTP.session.data(from: imageURL)
        guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw ImageGenerationError.noImageInResponse
        }
        return GeneratedImageResult(data: imageData, suggestedFileName: timestampedFileName(prefix: model))
    }
}

// MARK: - BYOK cloud (OpenAI-compatible)

/// The standard shape OpenAI's DALL-E/gpt-image and several compatible
/// providers speak — `POST {base}/images/generations`. Requests `b64_json`
/// explicitly rather than accepting the default `url`: OpenAI's generated-
/// image URLs expire after about an hour, and a base64 response avoids that
/// entirely along with the extra network hop.
enum OpenAICompatibleImageFormat {
    static func generate(baseURL: String, model: String, prompt: String, apiKey: String?) async throws -> GeneratedImageResult {
        guard let base = URL(string: baseURL) else { throw ImageGenerationError.invalidEndpoint }
        var request = URLRequest(url: base.appendingPathComponent("images/generations"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        if let apiKey, !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "response_format": "b64_json",
        ])

        let (data, response) = try await TransientHTTPRetry.sendData(request)
        guard response.statusCode == 200 else {
            throw ImageGenerationError.httpError(status: response.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let first = items.first else {
            throw ImageGenerationError.noImageInResponse
        }
        if let b64 = first["b64_json"] as? String, let imageData = Data(base64Encoded: b64) {
            return GeneratedImageResult(data: imageData, suggestedFileName: timestampedFileName(prefix: model))
        }
        // A provider that ignores response_format and sends a URL anyway —
        // fall back gracefully rather than failing outright.
        if let urlString = first["url"] as? String, let imageURL = URL(string: urlString) {
            let (imageData, imageResponse) = try await AppHTTP.session.data(from: imageURL)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else { throw ImageGenerationError.noImageInResponse }
            return GeneratedImageResult(data: imageData, suggestedFileName: timestampedFileName(prefix: model))
        }
        throw ImageGenerationError.noImageInResponse
    }
}

// MARK: - Local server (Automatic1111-compatible)

/// `POST {base}/sdapi/v1/txt2img` — Automatic1111's WebUI API, which
/// DrawThings' own HTTP API deliberately mimics for compatibility with
/// existing Stable Diffusion tooling, and which ComfyUI can also expose via
/// a compatibility shim. One implementation covers all three. Unlike the
/// cloud paths, there's no `model` field in the request — on every one of
/// these tools, which checkpoint runs is chosen in that tool's own UI, not
/// per-request; Eaon just asks whatever's currently loaded to generate.
enum Automatic1111ImageFormat {
    static func generate(baseURL: String, prompt: String) async throws -> GeneratedImageResult {
        guard let base = URL(string: baseURL) else { throw ImageGenerationError.invalidEndpoint }
        var request = URLRequest(url: base.appendingPathComponent("sdapi/v1/txt2img"))
        request.httpMethod = "POST"
        // Local generation on CPU/MPS can genuinely take minutes for a large
        // model — a much longer allowance than any cloud call needs.
        request.timeoutInterval = 300
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt])

        let (data, response) = try await TransientHTTPRetry.sendData(request)
        guard response.statusCode == 200 else {
            throw ImageGenerationError.httpError(status: response.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [String],
              let first = images.first,
              let imageData = Data(base64Encoded: first) else {
            throw ImageGenerationError.noImageInResponse
        }
        return GeneratedImageResult(data: imageData, suggestedFileName: timestampedFileName(prefix: "local"))
    }
}

// MARK: - Local Ollama-hosted image models

/// Ollama can now serve real diffusion models directly — verified live
/// against an actual locally-pulled model (`x/flux2-klein:4b`). Its usual
/// `/api/chat` flatly 400s on these ("does not support chat"); the real
/// working call is `POST /api/generate` (the older, non-chat completion
/// endpoint) with `{model, prompt, stream: false}`, and the image comes
/// back as base64 in the response's own `image` field — a fourth distinct
/// shape, matching none of Aqua's, OpenAI's, or Automatic1111's. A real
/// call against that exact model took ~31s for a 1024×1024 image, hence
/// the generous timeout, same as the other local path.
enum OllamaImageFormat {
    static func generate(model: String, prompt: String) async throws -> GeneratedImageResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt, "stream": false])

        let (data, response) = try await TransientHTTPRetry.sendData(request)
        guard response.statusCode == 200 else {
            throw ImageGenerationError.httpError(status: response.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["image"] as? String,
              let imageData = Data(base64Encoded: b64) else {
            throw ImageGenerationError.noImageInResponse
        }
        return GeneratedImageResult(data: imageData, suggestedFileName: timestampedFileName(prefix: "local-ollama"))
    }
}

// MARK: - Native tool call (any chat mode, not just the model picker)

/// The `eaon:image` fence's native-tool-calling mirror and its
/// system-prompt teaching text — mirrors `WebSearchTool`'s own doc comment
/// for why both channels exist side by side. Lets a plain text model (Aqua
/// or any other) generate an image mid-conversation via a tool call,
/// instead of requiring the user to switch the model picker to a dedicated
/// image model first.
enum ImageGenerationTool {
    static let nativeFunctionName = "generate_image"

    static let nativeDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": nativeFunctionName,
            "description": "Generate an image from a text description and show it to the user. Use this whenever the user asks you to create, draw, generate, or make an image, picture, illustration, logo, or similar visual — not for editing or analyzing an image they already sent you.",
            "parameters": [
                "type": "object",
                "properties": [
                    "prompt": [
                        "type": "string",
                        "description": "A clear, detailed description of the image to generate.",
                    ],
                ],
                "required": ["prompt"],
            ],
        ],
    ]

    /// Resolves which real backend actually generates the image, in the
    /// same priority order `sendImageGenerationMessage` already uses for
    /// the dedicated image-model path: a configured BYOK image provider
    /// first, then a locally pulled Ollama image model, then Aqua's
    /// hosted image models — each is a genuinely different account/setup,
    /// so this is the same "whatever the user has actually configured"
    /// order, not an arbitrary preference.
    enum Backend {
        case provider(config: ImageProviderConfig)
        case localOllama(record: LocalModelRecord)
        case aqua(model: String)
    }

    @MainActor
    static func resolveBackend() -> Backend? {
        if let config = ImageProviderStore.shared.configs.first {
            return .provider(config: config)
        }
        if let localRecord = LocalAIManager.shared.allLocalModels.first(where: { $0.isImageGeneration == true }) {
            return .localOllama(record: localRecord)
        }
        return nil
    }

    @MainActor
    static func generate(prompt: String, apiKey: String?) async throws -> GeneratedImageResult {
        guard let backend = resolveBackend() else {
            let aquaModels = await AquaImageModels.fetchAvailable()
            guard let firstAquaModel = aquaModels.first?.id else {
                throw ImageGenerationError.noImageInResponse
            }
            guard let apiKey, !apiKey.isEmpty else {
                throw ImageGenerationError.noImageInResponse
            }
            return try await AquaImageModels.generate(model: firstAquaModel, prompt: prompt, apiKey: apiKey)
        }
        switch backend {
        case .provider(let config):
            guard let modelId = config.trimmedModelIDs.first else {
                throw ImageGenerationError.noImageInResponse
            }
            let key = ImageProviderStore.shared.apiKey(for: config.id)
            return try await config.generate(model: modelId, prompt: prompt, apiKey: key)
        case .localOllama(let record):
            return try await OllamaImageFormat.generate(model: record.requestModelId, prompt: prompt)
        case .aqua(let model):
            guard let apiKey, !apiKey.isEmpty else {
                throw ImageGenerationError.noImageInResponse
            }
            return try await AquaImageModels.generate(model: model, prompt: prompt, apiKey: apiKey)
        }
    }

    /// Mirrors `WebSearchTool.agentInstructionBlock` — only sent (via
    /// `systemPromptHistory`) while `ImageGenerationStore.isEnabled` is
    /// true, so an off toggle removes both the native definition and this
    /// teaching text at once.
    static func agentInstructionBlock() -> String {
        """
        You can also generate images from a text description. Use it only when the user actually asks for an image, picture, illustration, logo, or similar visual to be created — never to illustrate a point unprompted.

        To generate an image, use a fenced block with the prompt as JSON:

        ```eaon:image
        {"prompt": "a detailed description of the image"}
        ```

        Always close the fence with ``` on its own line. The generated image is shown directly to the user — after it's created, just briefly confirm what you made; don't describe the image back to them as if they can't see it.
        """
    }
}

/// Whether the model is allowed to use `ImageGenerationTool` at all —
/// mirrors `WebSearchStore`. On by default; off means the teaching block
/// and native tool definition are never sent, and any `eaon:image` call is
/// refused at execution time too.
@MainActor
@Observable
final class ImageGenerationStore {
    static let shared = ImageGenerationStore()

    private static let enabledKey = "eaon_image_generation_tool_enabled"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.enabledKey)
    }
}
