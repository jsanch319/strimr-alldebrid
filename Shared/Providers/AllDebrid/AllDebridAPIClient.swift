import Foundation
import OSLog
import Security

/// AllDebrid v4 HTTP transport. Never embed an API key in source control or include request URLs in logs.
actor AllDebridAPIClient {
    private static let logger = Logger(subsystem: "com.strimr", category: "AllDebridPlayback")

    enum APIError: LocalizedError, Equatable {
        case invalidAPIKey
        case invalidResponse
        case pinExpired
        case serviceError(String)
        case httpStatus(Int)
        case invalidLink
        case playbackHTTPStatus(Int)
        case nonMediaContentType(String)

        var errorDescription: String? {
            switch self {
            case .invalidAPIKey: "An AllDebrid API key is required."
            case .invalidResponse: "AllDebrid returned an unexpected response."
            case .pinExpired: "The AllDebrid PIN expired. Start a new connection."
            case let .serviceError(message): message
            case let .httpStatus(status): "AllDebrid HTTP error: \(status)"
            case .invalidLink: "The playback link is invalid."
            case let .playbackHTTPStatus(status): "The resolved playback URL returned HTTP \(status)."
            case let .nonMediaContentType(contentType):
                "AllDebrid returned \(contentType) instead of a video file. The playback link could not be resolved."
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
              userURL.host == "alldebrid.com"
        else {
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
              let expiresIn = data["expires_in"] as? Int
        else {
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
              let user = data["user"] as? [String: Any]
        else {
            throw APIError.invalidResponse
        }
        return user["username"] as? String
    }

    /// Fetches the user's saved links. Response structure may vary by API version.
    func savedLinks() async throws -> [AllDebridSavedLink] {
        let payload = try await request("user/links")
        guard let data = payload["data"] as? [String: Any] else { throw APIError.invalidResponse }
        let rawLinks = (data["links"] as? [[String: Any]]) ?? []
        return rawLinks.compactMap { item in
            guard let link = item["link"] as? String, !link.isEmpty else { return nil }
            let filename = (item["filename"] as? String) ?? (item["name"] as? String) ?? "Untitled"
            return AllDebridSavedLink(id: String(describing: item["id"] ?? link), filename: filename, link: link)
        }
    }

    /// Fetches magnets of every status so an empty library can distinguish pending magnets from no magnets.
    func magnets() async throws -> [AllDebridMagnet] {
        let payload = try await request(
            "/v4.1/magnet/status",
            method: "POST",
            parametersInBody: true,
        )
        guard let data = payload["data"] as? [String: Any],
              let rawMagnets = data["magnets"] as? [Any] else { throw APIError.invalidResponse }

        let magnets: [AllDebridMagnet] = rawMagnets.compactMap { rawMagnet -> AllDebridMagnet? in
            guard let magnet = rawMagnet as? [String: Any],
                  let id = Self.stringValue(magnet["id"]) else { return nil }
            let status = magnet["status"] as? String ?? ""
            let statusCode = Self.integerValue(magnet["statusCode"])
                ?? Self.integerValue(magnet["statuscode"])
                ?? Self.integerValue(magnet["status"])
            return AllDebridMagnet(
                id: id,
                filename: (magnet["filename"] as? String) ?? (magnet["name"] as? String) ?? "Untitled",
                size: Self.integerValue(magnet["size"]) ?? 0,
                status: status,
                statusCode: statusCode.flatMap { Int(exactly: $0) },
            )
        }
        guard magnets.count == rawMagnets.count else { throw APIError.invalidResponse }
        return magnets
    }

    /// Fetches playable files for multiple ready magnets and recursively flattens their folder trees.
    func magnetFiles(for magnetIDs: [String]) async throws -> [AllDebridMagnetFile] {
        let ids = Array(Set(magnetIDs)).sorted()
        guard !ids.isEmpty else { return [] }
        let parameters = ids.map { URLQueryItem(name: "id[]", value: $0) }
        let payload = try await request(
            "/v4/magnet/files",
            parameters: parameters,
            method: "POST",
            parametersInBody: true,
        )
        guard let data = payload["data"] as? [String: Any] else { throw APIError.invalidResponse }

        var files: [AllDebridMagnetFile] = []
        if let magnets = data["magnets"] as? [Any] {
            for rawMagnet in magnets {
                guard let magnet = rawMagnet as? [String: Any],
                      let magnetID = Self.stringValue(magnet["id"]),
                      ids.contains(magnetID),
                      let entries = magnet["files"] as? [Any] else { continue }
                Self.flatten(entries, magnetID: magnetID, parentPath: "", into: &files)
            }
        } else if ids.count == 1, let entries = data["files"] as? [Any] {
            Self.flatten(entries, magnetID: ids[0], parentPath: "", into: &files)
        } else {
            throw APIError.invalidResponse
        }
        return files
    }

    /// Resolves an AllDebrid link to a streamable URL and confirms the result is not an API or web page.
    func unlock(_ link: String) async throws -> URL {
        guard let candidate = URL(string: link),
              ["https", "http"].contains(candidate.scheme?.lowercased() ?? ""),
              candidate.host != nil else { throw APIError.invalidLink }
        let payload = try await request(
            "link/unlock",
            parameters: [URLQueryItem(name: "link", value: link)],
            method: "POST",
            parametersInBody: true,
        )
        guard let data = payload["data"] as? [String: Any],
              let rawURL = data["link"] as? String,
              let url = URL(string: rawURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { throw APIError.invalidResponse }
        return url
    }

    func resolvePlaybackURL(_ link: String, filename: String) async throws -> AllDebridPlaybackResolution {
        Self.logger.debug(
            "Resolving playback source: filename=\(filename, privacy: .public), originalURL=\(Self.logSafeURL(link), privacy: .public)",
        )
        let unlockedURL = try await unlock(link)
        var request = URLRequest(url: unlockedURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        let finalURL = response.url ?? unlockedURL
        let resolution = AllDebridPlaybackResolution(
            url: finalURL,
            statusCode: response.statusCode,
            contentType: contentType,
            followedRedirect: finalURL != unlockedURL,
        )
        Self.logger.debug(
            "Playback resolved: filename=\(filename, privacy: .public), originalURL=\(Self.logSafeURL(link), privacy: .public), finalURL=\(Self.logSafeURL(finalURL.absoluteString), privacy: .public), status=\(resolution.statusCode), contentType=\(contentType ?? "missing", privacy: .public), redirected=\(resolution.followedRedirect)",
        )
        guard (200 ... 299).contains(response.statusCode) else {
            throw APIError.playbackHTTPStatus(response.statusCode)
        }
        if let contentType, Self.isNonMediaContentType(contentType) {
            throw APIError.nonMediaContentType(contentType)
        }
        return resolution
    }

    private static func isNonMediaContentType(_ contentType: String) -> Bool {
        let normalizedType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalizedType.hasPrefix("text/")
            || normalizedType.contains("json")
            || normalizedType.contains("html")
            || normalizedType.contains("xml")
    }

    nonisolated static func logSafeURL(_ string: String) -> String {
        guard let url = URL(string: string), let host = url.host else { return "<invalid-url>" }
        let pathExtension = (url.path as NSString).pathExtension
        let pathSuffix = pathExtension.isEmpty ? "" : "/<redacted>.\(pathExtension)"
        return "\(url.scheme ?? "https")://\(host)/<redacted>\(pathSuffix)"
    }

    private func request(
        _ path: String,
        parameters: [URLQueryItem] = [],
        method: String = "GET",
        parametersInBody: Bool = false,
    ) async throws -> [String: Any] {
        guard let apiKey else { throw APIError.invalidAPIKey }
        guard let endpoint = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else {
            throw APIError.invalidResponse
        }
        let requestParameters = [
            URLQueryItem(name: "agent", value: "StrimrAllDebridPrototype"),
            URLQueryItem(name: "apikey", value: apiKey),
        ] + parameters
        if parametersInBody {
            components.queryItems = nil
        } else {
            components.queryItems = requestParameters
        }
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if parametersInBody {
            var bodyComponents = URLComponents()
            bodyComponents.queryItems = requestParameters
            guard let body = bodyComponents.percentEncodedQuery?.data(using: .utf8) else {
                throw APIError.invalidResponse
            }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return try await send(request)
    }

    private static func flatten(
        _ entries: [Any],
        magnetID: String,
        parentPath: String,
        into files: inout [AllDebridMagnetFile],
    ) {
        for rawEntry in entries {
            guard let entry = rawEntry as? [String: Any],
                  let name = entry["n"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let fullPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
            if let children = entry["e"] as? [Any] {
                flatten(children, magnetID: magnetID, parentPath: fullPath, into: &files)
            }
            guard let link = entry["l"] as? String,
                  let url = URL(string: link),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { continue }
            let size = integerValue(entry["s"]) ?? 0
            files.append(
                AllDebridMagnetFile(
                    id: "\(magnetID):\(fullPath):\(size)",
                    magnetID: magnetID,
                    filename: name,
                    fullPath: fullPath,
                    size: size,
                    link: link,
                ),
            )
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func integerValue(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int:
            Int64(value)
        case let value as Int64:
            value
        case let value as NSNumber:
            value.int64Value
        case let value as String:
            Int64(value)
        default:
            nil
        }
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (responseData, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200 ... 299).contains(response.statusCode) else { throw APIError.httpStatus(response.statusCode) }
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

struct AllDebridPlaybackResolution: Sendable {
    let url: URL
    let statusCode: Int
    let contentType: String?
    let followedRedirect: Bool
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
