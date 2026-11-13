import Foundation

/// Experimental AllDebrid v4 HTTP transport. Not yet connected to Strimr's UI.
/// Never embed an API key in source control or include request URLs in logs.
actor AllDebridAPIClient {
    enum APIError: LocalizedError {
        case invalidAPIKey
        case invalidResponse
        case serviceError(String)
        case httpStatus(Int)
        case invalidLink

        var errorDescription: String? {
            switch self {
            case .invalidAPIKey: return "An AllDebrid API key is required."
            case .invalidResponse: return "AllDebrid returned an unexpected response."
            case .serviceError(let message): return message
            case .httpStatus(let status): return "AllDebrid HTTP error: \(status)"
            case .invalidLink: return "The playback link is invalid."
            }
        }
    }

    private let apiKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.alldebrid.com/v4/")!

    init(apiKey: String, session: URLSession = .shared) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIError.invalidAPIKey }
        self.apiKey = key
        self.session = session
    }

    /// Fetches the user's saved links. Response structure may vary by API version.
    func savedLinks() async throws -> [AllDebridSavedLink] {
        let payload = try await request("user/links")
        guard let data = payload["data"] as? [String: Any] else { return [] }
        let rawLinks = (data["links"] as? [[String: Any]]) ?? []
        return rawLinks.compactMap { item in
            guard let link = item["link"] as? String, !link.isEmpty else { return nil }
            let filename = (item["filename"] as? String) ?? (item["name"] as? String) ?? "Untitled"
            return AllDebridSavedLink(id: String(describing: item["id"] ?? link), filename: filename, link: link)
        }
    }

    /// Resolves an AllDebrid link to a streamable URL. Resolve again when expired.
    func unlock(_ link: String) async throws -> URL {
        guard let candidate = URL(string: link),
              ["https", "http"].contains(candidate.scheme?.lowercased() ?? ""),
              candidate.host != nil else { throw APIError.invalidLink }
        let payload = try await request("link/unlock", parameters: [URLQueryItem(name: "link", value: link)])
        guard let data = payload["data"] as? [String: Any],
              let rawURL = data["link"] as? String,
              let url = URL(string: rawURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { throw APIError.invalidResponse }
        return url
    }

    private func request(_ path: String, parameters: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let endpoint = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "agent", value: "StrimrAllDebridPrototype"),
            URLQueryItem(name: "apikey", value: apiKey)
        ] + parameters
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (responseData, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw APIError.httpStatus(response.statusCode) }
        guard let payload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        if let status = payload["status"] as? String, status.lowercased() == "error" {
            let error = payload["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? "AllDebrid request failed."
            throw APIError.serviceError(message)
        }
        return payload
    }
}

struct AllDebridSavedLink: Sendable, Identifiable, Hashable {
    let id: String
    let filename: String
    let link: String

    var isVideo: Bool {
        let path = filename.lowercased()
        return [".mkv", ".mp4", ".m4v", ".mov", ".avi", ".webm"].contains { path.hasSuffix($0) }
    }
}
