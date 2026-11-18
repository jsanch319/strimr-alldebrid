import Foundation

nonisolated struct StremioManifest: Decodable, Sendable {
    struct Resource: Decodable, Sendable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                name = text; types = nil; idPrefixes = nil
            } else {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                types = try c.decodeIfPresent([String].self, forKey: .types)
                idPrefixes = try c.decodeIfPresent([String].self, forKey: .idPrefixes)
            }
        }

        enum CodingKeys: CodingKey { case name, types, idPrefixes }
    }

    struct Hints: Decodable, Sendable { let configurationRequired: Bool? }
    let id: String
    let version: String
    let name: String
    let types: [String]
    let resources: [Resource]
    let idPrefixes: [String]?
    let behaviorHints: Hints?
    func supports(_ type: String, id: String? = nil) -> Bool {
        func accepts(_ prefixes: [String]?) -> Bool {
            guard let prefixes else { return true }
            return prefixes
                .contains { prefix in
                    id.map { $0.hasPrefix(prefix) } ?? (prefix.hasPrefix("tt") || "tt".hasPrefix(prefix))
                }
        }
        return types.contains(type) && accepts(idPrefixes) && resources.contains {
            $0.name == "stream" && ($0.types == nil || $0.types!.contains(type)) && accepts($0.idPrefixes)
        }
    }
}

/// Raw add-on labels and URLs never enter display models or logs.
nonisolated struct StremioStream: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Hints: Decodable, Sendable {
        let filename: String?
        let proxyHeaders: [String: [String: String]]?
    }

    let name: String?
    let title: String?
    let displayDetails: String?
    enum CodingKeys: String, CodingKey {
        case name, title, url, infoHash, behaviorHints
        case displayDetails = "description"
    }

    let url: String?
    let infoHash: String?
    let behaviorHints: Hints?
    var description: String {
        "Stremio stream (redacted)"
    }

    var debugDescription: String {
        description
    }
}

nonisolated protocol StremioClientProtocol: Sendable {
    func manifest(_ configuration: StremioConfiguration) async throws -> StremioManifest
    func streams(_ configuration: StremioConfiguration, type: String, id: String) async throws -> [StremioStream]
    func playbackURL(_ url: URL) async throws -> URL
}

/// Ephemeral transport: no disk URL cache or cookies. Metadata redirects must retain the configured origin.
actor StremioClient: StremioClientProtocol {
    private let configuration: URLSessionConfiguration
    init(session: URLSession? = nil) {
        configuration = session?.configuration ?? .ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    }

    func manifest(_ configuration: StremioConfiguration) async throws -> StremioManifest {
        let data = try await fetch(configuration.manifestURL)
        guard let manifest = try? JSONDecoder().decode(StremioManifest.self, from: data),
              !manifest.id.isEmpty, !manifest.name.isEmpty,
              !manifest.version.isEmpty else { throw StremioError.invalidManifest }
        guard manifest.behaviorHints?.configurationRequired != true,
              manifest.supports("movie") || manifest.supports("series") else { throw StremioError.unsupportedManifest }
        return manifest
    }

    func streams(_ configuration: StremioConfiguration, type: String, id: String) async throws -> [StremioStream] {
        let data = try await fetch(configuration.streamURL(type: type, id: id))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["streams"] as? [[String: Any]] else { throw StremioError.noSources }
        return raw.prefix(100).compactMap { row in
            guard row["drm"] == nil, row["licenseUrl"] == nil, row["licenseKey"] == nil,
                  row["ytId"] == nil, row["externalUrl"] == nil,
                  let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? JSONDecoder().decode(StremioStream.self, from: data)
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        do {
            let delegate = StremioSecureRedirect(origin: url)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url); request.timeoutInterval = 20
            let (data, raw) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = raw as? HTTPURLResponse else { throw StremioError.connection }
            if response.statusCode == 429 {
                throw StremioError.rateLimited
            }
            guard (200 ... 299).contains(response.statusCode),
                  data.count <= 1_048_576 else { throw StremioError.connection }
            return data
        } catch {
            if error.isCancellation {
                throw CancellationError()
            }
            throw (error as? StremioError) ?? .connection
        }
    }

    func playbackURL(_ url: URL) async throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil else { throw StremioError.unsupportedSource }
        do {
            let delegate = StremioSecureRedirect(origin: nil)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url); request.httpMethod = "HEAD"; request.timeoutInterval = 20
            var (_, response) = try await session.data(for: request)
            if let head = response as? HTTPURLResponse, [401, 403, 405, 501].contains(head.statusCode) {
                let probe = StremioMediaProbe()
                let headers = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
                defer { headers.invalidateAndCancel() }
                request.httpMethod = "GET"; request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                response = try await withTaskCancellationHandler {
                    try await probe.response(session: headers, request: request)
                } onCancel: { headers.invalidateAndCancel() }
            }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200 ... 299).contains(response.statusCode),
                  let final = response.url, final.scheme?.lowercased() == "https" else { throw StremioError.playback }
            let mime = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard !mime.hasPrefix("text/"), !mime.hasPrefix("image/"), !mime.contains("json"), !mime.contains("html"),
                  !mime.contains("xml") else { throw StremioError.playback }
            return final
        } catch {
            if error.isCancellation {
                throw CancellationError()
            }
            throw StremioError.playback
        }
    }
}

nonisolated class StremioSecureRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL?
    init(origin: URL?) {
        self.origin = origin
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void,
    ) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil,
              url.password == nil else { completionHandler(nil); return }
        if let origin, url.host != origin.host || (url.port ?? 443) != (origin.port ?? 443) {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

/// A Range-ignoring host must never cause a full movie to buffer during availability checks.
private final nonisolated class StremioMediaProbe: StremioSecureRedirect, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    init() {
        super.init(origin: nil)
    }

    func response(session: URLSession, request: URLRequest) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void,
    ) {
        finish(.success(response)); completionHandler(.cancel)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URLResponse, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
