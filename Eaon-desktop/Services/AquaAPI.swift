import Foundation

enum AquaAPI {
    static let baseURL = URL(string: "https://api.aquadevs.com/v1")!

    static var modelsURL: URL {
        baseURL.appendingPathComponent("models")
    }

    static var chatCompletionsURL: URL {
        baseURL.appendingPathComponent("chat/completions")
    }
}

struct AquaAPIService {
    func fetchModels() async throws -> [APIModel] {
        let (data, response) = try await URLSession.shared.data(from: AquaAPI.modelsURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AquaAPIError.badResponse
        }

        let decoded = try JSONDecoder().decode(APIModelResponse.self, from: data)
        return AquaSupportedModels.filterSupported(decoded.data)
            .sorted { lhs, rhs in
                lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
    }
}

enum AquaAPIError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Could not load models from the Aqua API."
        }
    }
}

extension APIModel {
    /// Chat completions only support text models from the Aqua catalog.
    var isChatModel: Bool {
        (type ?? "text").lowercased() == "text"
    }
}
