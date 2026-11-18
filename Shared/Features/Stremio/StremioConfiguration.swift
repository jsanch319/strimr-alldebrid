import Foundation

nonisolated enum StremioError: LocalizedError {
    case invalidURL, invalidManifest, unsupportedManifest, connection, missingIMDb, noSources, unsupportedSource,
         playback, rateLimited
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Paste a configured HTTPS or stremio:// add-on URL ending in /manifest.json."
        case .invalidManifest: "The add-on did not return a valid Stremio manifest."
        case .unsupportedManifest: "This add-on does not support IMDb movie/series streams, or still requires configuration."
        case .connection: "The add-on could not be reached. Check its configuration or try again. Sensitive URL details are hidden."
        case .missingIMDb: "An IMDb ID is required for this title. Refresh TMDb metadata before trying again."
        case .noSources: "The configured add-on returned no compatible sources for this title or episode. Availability is not guaranteed."
        case .unsupportedSource: "This source is unsupported. Use an authorized HTTPS video stream or a supported AllDebrid link."
        case .playback: "The add-on stream could not be played. Its link may have expired or the format may be unsupported."
        case .rateLimited: "The add-on is rate limited. Wait before retrying."
        }
    }
}

nonisolated struct StremioConfiguration: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let manifestURL: URL
    let authorized: Bool
    var description: String {
        "Stremio configuration (URL redacted)"
    }

    var debugDescription: String {
        description
    }

    init(url: String, authorized: Bool) throws {
        var c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
        if c?.scheme?.lowercased() == "stremio" {
            c?.scheme = "https"
        }
        guard let c, c.scheme?.lowercased() == "https", c.host != nil,
              c.user == nil, c.password == nil, c.fragment == nil,
              c.path.hasSuffix("/manifest.json"), let url = c.url else { throw StremioError.invalidURL }
        manifestURL = url; self.authorized = authorized
    }

    func streamURL(type: String, id: String) -> URL {
        var c = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)!
        let path = c.percentEncodedPath
        c.percentEncodedPath = String(path.prefix(through: path.lastIndex(of: "/")!)) + "stream/\(type)/\(id).json"
        return c.url!
    }

    func safeName(_ value: String) -> String {
        let components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)!
        let path = components.path.components(separatedBy: "/").dropLast().joined(separator: "/")
        let values = (components.queryItems ?? []).compactMap(\.value).joined(separator: "/")
        let tokens = (path + "/" + values).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let name = String(value
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .prefix(60))
        guard !name.contains("://"), !name.contains("="), !name.contains("/"), !name.contains("%"),
              !tokens.contains(where: { name.localizedCaseInsensitiveContains($0) })
        else { return "Configured Stremio Add-on" }
        return name.isEmpty ? "Stremio Add-on" : name
    }
}

@MainActor
protocol StremioConfigurationStorage {
    func load() throws -> StremioConfiguration?
    func save(_ configuration: StremioConfiguration) throws
    func delete() throws
}

/// All configuration, including credential-bearing path/query values, is Keychain-only.
@MainActor
struct StremioConfigurationStore: StremioConfigurationStorage {
    private let keychain = Keychain(service: "com.strimr.stremio-addons")
    func load() throws -> StremioConfiguration? {
        guard let raw = try keychain.string(forKey: "configuration") else { return nil }
        guard let data = raw.data(using: .utf8), let saved = try? JSONDecoder().decode(
            StremioConfiguration.self,
            from: data,
        ) else { throw StremioError.invalidURL }
        return try StremioConfiguration(url: saved.manifestURL.absoluteString, authorized: saved.authorized)
    }

    func save(_ configuration: StremioConfiguration) throws {
        let raw = try String(decoding: JSONEncoder().encode(configuration), as: UTF8.self)
        try keychain.setString(raw, forKey: "configuration")
        NotificationCenter.default.post(name: .stremioAddonsDidChange, object: nil)
    }

    func delete() throws {
        try keychain.deleteValue(forKey: "configuration")
        NotificationCenter.default.post(name: .stremioAddonsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let stremioAddonsDidChange = Notification.Name("com.strimr.stremioAddonsDidChange")
}
