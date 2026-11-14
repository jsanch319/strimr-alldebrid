import Foundation
import Security

/// AllDebrid v4 HTTP transport. Never embed an API key in source control or include request URLs in logs.
actor AllDebridAPIClient {
    enum APIError: LocalizedError, Equatable {
        case invalidAPIKey
        case invalidResponse
        case pinExpired
        case serviceError(String)
        case httpStatus(Int)
        case invalidLink

        var errorDescription: String? {
            switch self {
            case .invalidAPIKey: return "An AllDebrid API key is required."
            case .invalidResponse: return "AllDebrid returned an unexpected response."
            case .pinExpired: return "The AllDebrid PIN expired. Start a new connection."
            case .serviceError(let message): return message
            case .httpStatus(let status): return "AllDebrid HTTP error: \(status)"
            case .invalidLink: return "The playback link is invalid."
            }
        }
    }

    private let apiKey: String?
    private let session: URLSession
    private let baseURL = URL(string: "https://api.alldebrid.com/v4/")!

    init(apiKey: String, session: URLSession = .shared) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIError.invalidAPIKey }
        self.apiKey = key
        self.session = session
    }

    init(session: URLSession = .shared) {
        apiKey = nil
        self.session = session
    }

    func requestPIN() async throws -> AllDebridPIN {
        let url = URL(string: "https://api.alldebrid.com/v4.1/pin/get")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let payload = try await send(request)

        guard payload["status"] as? String == "success",
              let data = payload["data"] as? [String: Any],
              let pin = data["pin"] as? String,
              let check = data["check"] as? String,
              let expiresIn = data["expires_in"] as? Int,
              expiresIn > 0,
              let rawUserURL = data["user_url"] as? String,
              let userURL = URL(string: rawUserURL),
              userURL.scheme == "https",
              userURL.host == "alldebrid.com" else {
            throw APIError.invalidResponse
        }
        return AllDebridPIN(pin: pin, check: check, expiresIn: expiresIn, userURL: userURL)
    }

    func checkPIN(pin: String, check: String) async throws -> AllDebridPINStatus {
        let url = URL(string: "https://api.alldebrid.com/v4/pin/check")!
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "pin", value: pin),
            URLQueryItem(name: "check", value: check),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let payload = try await send(request)

        guard payload["status"] as? String == "success",
              let data = payload["data"] as? [String: Any],
              let activated = data["activated"] as? Bool,
              let expiresIn = data["expires_in"] as? Int else {
            throw APIError.invalidResponse
        }
        return AllDebridPINStatus(
            activated: activated,
            expiresIn: expiresIn,
            apiKey: data["apikey"] as? String,
        )
    }

    @discardableResult
    func verifyConnection() async throws -> String? {
        guard let apiKey else { throw APIError.invalidAPIKey }
        let url = URL(string: "https://api.alldebrid.com/v4/user")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let payload = try await send(request)

        guard payload["status"] as? String == "success",
              let data = payload["data"] as? [String: Any],
              let user = data["user"] as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return user["username"] as? String
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
        guard let apiKey else { throw APIError.invalidAPIKey }
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
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
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
            if error?["code"] as? String == "PIN_EXPIRED" {
                throw APIError.pinExpired
            }
            let message = (error?["message"] as? String) ?? "AllDebrid request failed."
            throw APIError.serviceError(message)
        }
        return payload
    }
}

struct AllDebridPIN: Sendable {
    let pin: String
    let check: String
    let expiresIn: Int
    let userURL: URL
}

struct AllDebridPINStatus: Sendable {
    let activated: Bool
    let expiresIn: Int
    let apiKey: String?
}

struct AllDebridCredentialStore {
    private let service = "com.strimr.experimental.alldebrid"
    private let account = "api-key"

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidItem
        }
        return apiKey
    }

    func save(_ apiKey: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(deleteStatus)
        }
        let attributes = query.merging([
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(apiKey.utf8),
        ]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
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
