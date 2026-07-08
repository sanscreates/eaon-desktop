import Foundation

/// Executes a chat completion against a user-configured BYOK provider, in
/// whichever wire format that provider actually speaks, feeding text deltas
/// into the same `TypewriterStreamController` the Aqua path already uses.
///
/// Implemented against each provider's public documentation for their
/// standard, current API shape — not live-tested against a real key for any
/// of the three formats (that would require the user's own paid credentials).
/// If a specific provider's response shape has since changed, streaming will
/// surface a clear error rather than silently mis-rendering.
struct CustomProviderAPIService {
    func streamCompletion(
        config: CustomProviderConfig,
        apiKey: String,
        modelId: String,
        history: [(role: String, content: String)],
        typewriter: TypewriterStreamController
    ) async throws {
        guard let base = URL(string: config.baseURL), !config.baseURL.isEmpty else {
            throw APIClientError.unexpectedResponse("\"\(config.baseURL)\" isn't a valid base URL.")
        }

        switch config.format {
        case .openAICompatible:
            try await streamOpenAICompatible(base: base, apiKey: apiKey, modelId: modelId, history: history, typewriter: typewriter)
        case .anthropicMessages:
            try await streamAnthropicMessages(base: base, apiKey: apiKey, modelId: modelId, history: history, typewriter: typewriter)
        case .googleGemini:
            try await streamGoogleGemini(base: base, apiKey: apiKey, modelId: modelId, history: history, typewriter: typewriter)
        }
    }

    // MARK: - OpenAI-compatible

    private func streamOpenAICompatible(
        base: URL,
        apiKey: String,
        modelId: String,
        history: [(role: String, content: String)],
        typewriter: TypewriterStreamController
    ) async throws {
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let apiMessages = history.map { ["role": $0.role, "content": $0.content] }
        let body: [String: Any] = ["model": modelId, "messages": apiMessages, "stream": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode != 200 {
            throw APIClientError.httpError(status: http.statusCode, message: try await Self.readErrorBody(bytes))
        }

        var sawContent = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }

            sawContent = true
            await typewriter.append(content)
            await StatisticsTracker.shared.recordGeneratedCharacters(content.count)
        }
        if !sawContent { throw APIClientError.emptyResponse }
    }

    // MARK: - Anthropic Messages API

    private func streamAnthropicMessages(
        base: URL,
        apiKey: String,
        modelId: String,
        history: [(role: String, content: String)],
        typewriter: TypewriterStreamController
    ) async throws {
        var request = URLRequest(url: base.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Anthropic has no "system" role inside `messages` — it's a separate
        // top-level field.
        let systemText = history.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let turns = history.filter { $0.role != "system" }.map { ["role": $0.role, "content": $0.content] }

        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": 4096,
            "messages": turns,
            "stream": true,
        ]
        if !systemText.isEmpty { body["system"] = systemText }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode != 200 {
            throw APIClientError.httpError(status: http.statusCode, message: try await Self.readErrorBody(bytes))
        }

        var sawContent = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                sawContent = true
                await typewriter.append(text)
                await StatisticsTracker.shared.recordGeneratedCharacters(text.count)
            } else if type == "message_stop" {
                break
            }
        }
        if !sawContent { throw APIClientError.emptyResponse }
    }

    // MARK: - Google Gemini API

    private func streamGoogleGemini(
        base: URL,
        apiKey: String,
        modelId: String,
        history: [(role: String, content: String)],
        typewriter: TypewriterStreamController
    ) async throws {
        guard var components = URLComponents(
            url: base.appendingPathComponent("models/\(modelId):streamGenerateContent"),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIClientError.unexpectedResponse("Could not build a Gemini request URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "alt", value: "sse"),
        ]
        guard let url = components.url else {
            throw APIClientError.unexpectedResponse("Could not build a Gemini request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Gemini's roles are "user"/"model" (not "assistant"), and it has no
        // system role inside `contents` — fold any system turns into the
        // front of the first user turn instead.
        let systemText = history.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        var contents: [[String: Any]] = history
            .filter { $0.role != "system" }
            .map { ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.content]]] }

        if !systemText.isEmpty, !contents.isEmpty,
           var parts = contents[0]["parts"] as? [[String: Any]],
           var firstPart = parts.first,
           let firstText = firstPart["text"] as? String {
            firstPart["text"] = systemText + "\n\n" + firstText
            parts[0] = firstPart
            contents[0]["parts"] = parts
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: ["contents": contents])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode != 200 {
            throw APIClientError.httpError(status: http.statusCode, message: try await Self.readErrorBody(bytes))
        }

        var sawContent = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else { continue }

            sawContent = true
            await typewriter.append(text)
            await StatisticsTracker.shared.recordGeneratedCharacters(text.count)
        }
        if !sawContent { throw APIClientError.emptyResponse }
    }

    // MARK: - Model discovery

    /// Calls the provider's own model-listing endpoint so the editor sheet
    /// can auto-fill the "Models" field instead of requiring the user to
    /// know and type exact model IDs by hand. Same per-format auth as
    /// `streamCompletion` above — just a GET instead of a POST — since
    /// that's the one thing each format's real API actually requires.
    /// Manual entry stays available in the UI for whenever this fails (a
    /// self-hosted or proxy endpoint that doesn't implement listing, a
    /// restricted key, a shape that's since changed).
    func fetchAvailableModels(baseURL: String, format: APIRequestFormat, apiKey: String) async throws -> [String] {
        guard let base = URL(string: baseURL), !baseURL.isEmpty else {
            throw APIClientError.unexpectedResponse("\"\(baseURL)\" isn't a valid base URL.")
        }
        switch format {
        case .openAICompatible:
            return try await fetchOpenAICompatibleModels(base: base, apiKey: apiKey)
        case .anthropicMessages:
            return try await fetchAnthropicModels(base: base, apiKey: apiKey)
        case .googleGemini:
            return try await fetchGoogleModels(base: base, apiKey: apiKey)
        }
    }

    private func fetchOpenAICompatibleModels(base: URL, apiKey: String) async throws -> [String] {
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await Self.getJSON(request)

        struct Entry: Decodable { let id: String }
        struct ListResponse: Decodable { let data: [Entry] }
        return try JSONDecoder().decode(ListResponse.self, from: data).data.map(\.id)
    }

    private func fetchAnthropicModels(base: URL, apiKey: String) async throws -> [String] {
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let data = try await Self.getJSON(request)

        struct Entry: Decodable { let id: String }
        struct ListResponse: Decodable { let data: [Entry] }
        return try JSONDecoder().decode(ListResponse.self, from: data).data.map(\.id)
    }

    private func fetchGoogleModels(base: URL, apiKey: String) async throws -> [String] {
        guard var components = URLComponents(
            url: base.appendingPathComponent("models"),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIClientError.unexpectedResponse("Could not build a Gemini models request URL.")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw APIClientError.unexpectedResponse("Could not build a Gemini models request URL.")
        }
        let data = try await Self.getJSON(URLRequest(url: url))

        // Google lists ids as "models/gemini-..." — strip the prefix so it
        // matches the bare id `streamGoogleGemini` itself expects (it builds
        // "models/<id>:streamGenerateContent" back up from the bare id).
        struct Entry: Decodable { let name: String }
        struct ListResponse: Decodable { let models: [Entry] }
        return try JSONDecoder().decode(ListResponse.self, from: data).models.map {
            $0.name.hasPrefix("models/") ? String($0.name.dropFirst("models/".count)) : $0.name
        }
    }

    private static func getJSON(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw APIClientError.httpError(status: http.statusCode, message: Self.readErrorBody(data))
        }
        return data
    }

    private static func readErrorBody(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String { return detail }
            if let message = json["message"] as? String { return message }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    // MARK: - Shared

    private static func readErrorBody(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var collected = Data()
        for try await byte in bytes { collected.append(byte) }

        if let json = try? JSONSerialization.jsonObject(with: collected) as? [String: Any] {
            if let detail = json["detail"] as? String { return detail }
            if let message = json["message"] as? String { return message }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        }
        return String(data: collected, encoding: .utf8) ?? "Unknown error"
    }
}
