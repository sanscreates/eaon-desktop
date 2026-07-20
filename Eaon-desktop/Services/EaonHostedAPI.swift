import Foundation

enum EaonHostedAPI {
    static let baseURL = URL(string: "https://api.aquadevs.com/v1")!

    static var modelsURL: URL {
        baseURL.appendingPathComponent("models")
    }

    static var chatCompletionsURL: URL {
        baseURL.appendingPathComponent("chat/completions")
    }
}

struct EaonHostedAPIService {
    func fetchModels() async throws -> [APIModel] {
        // During a free-week trial (no user key), the list comes from Eaon's
        // gateway — signed, and already server-filtered to the models the
        // trial plan can actually run. With a user key (or no access at
        // all), the public Aqua list is fetched exactly as before.
        var request: URLRequest
        if let access = EaonAccess.current, access.isTrial {
            request = URLRequest(url: access.modelsURL)
            EaonAccess.authorize(&request, apiKey: access.apiKey)
        } else {
            request = URLRequest(url: EaonHostedAPI.modelsURL)
        }
        request.timeoutInterval = 30
        // Same gateway that flaps 502 on chat completions serves this list —
        // retry transient 5xx so one blip during an origin hiccup doesn't
        // leave the model picker empty.
        let (data, response) = try await TransientHTTPRetry.sendData(request)

        guard response.statusCode == 200 else {
            throw EaonHostedAPIError.badResponse
        }

        let decoded = try JSONDecoder().decode(APIModelResponse.self, from: data)
        return EaonHostedModels.filterSupported(decoded.data)
            .sorted { lhs, rhs in
                lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
    }
}

enum EaonHostedAPIError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Could not load models from Eaon's hosted API."
        }
    }
}

extension APIModel {
    /// Chat completions only support text models from the Aqua catalog.
    var isChatModel: Bool {
        (type ?? "text").lowercased() == "text"
    }
}
