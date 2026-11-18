import Foundation

/// Public source labels contain no remote URLs, configuration, raw add-on titles or credentials.
nonisolated struct StremioSourceLabel: Identifiable, Hashable, Sendable {
    let id: String
    let filename: String
    let quality: Int
    var audioHint: StremioAudioHint = .unknown
    var fileIndex: Int?
    var unsupportedReason: String?
}

@MainActor
final class StremioPlaybackSources {
    private struct Entry {
        let label: StremioSourceLabel
        let link: String
        let direct: Bool
        var submitted = false
        var magnetID: String?
        var submittedAt: Date?
    }

    private let client: any StremioClientProtocol
    private let store: any StremioConfigurationStorage
    private var entries: [Entry] = []
    private var cachedIdentity: String?
    private var cachedAt: Date?
    private var configuration: StremioConfiguration?
    private(set) var configured = false

    init(
        client: any StremioClientProtocol = StremioClient(),
        store: (any StremioConfigurationStorage)? = nil,
    ) {
        self.client = client; self.store = store ?? StremioConfigurationStore()
    }

    static func identity(title: TMDBTitle, episode: TMDBEpisode?) throws -> (type: String, id: String) {
        guard let imdb = title.matchingIDs.imdb,
              imdb.range(of: #"^tt\d{5,12}$"#, options: .regularExpression) != nil
        else { throw StremioError.missingIMDb }
        if title.kind == .movie {
            return ("movie", imdb)
        }
        guard let episode, episode.season_number >= 0,
              episode.episode_number > 0 else { throw CatalogSourceResolver.Failure.chooseEpisode }
        return ("series", "\(imdb):\(episode.season_number):\(episode.episode_number)")
    }

    func discover(
        title: TMDBTitle,
        episode: TMDBEpisode?,
        preferEnglish: Bool = true,
    ) async throws -> [AllDebridTitleMatcher.Source] {
        if configuration == nil {
            configuration = try store.load()
        }
        guard let configuration, configuration.authorized else { configured = false; return [] }
        configured = true
        let identity = try Self.identity(title: title, episode: episode)
        let key = "\(title.kind):\(title.id):\(identity.id)"
        if cachedIdentity != key || cachedAt == nil || Date().timeIntervalSince(cachedAt!) >= 60 {
            entries = []; cachedIdentity = key; cachedAt = nil
            let manifest = try await client.manifest(configuration)
            guard manifest.supports(identity.type, id: identity.id) else { throw StremioError.unsupportedManifest }
            let streams = try await client.streams(configuration, type: identity.type, id: identity.id)
            try Task.checkCancellation()
            cachedAt = Date()
            var seen = Set<String>()
            for (ordinal, stream) in streams.enumerated() {
                let filename = stream.behaviorHints?.filename
                var reason = stream.unsupportedReason
                if stream.behaviorHints?.proxyHeaders?.values.contains(where: { !$0.isEmpty }) == true {
                    reason = "Custom proxy headers are not supported by this source path."
                }
                if !StremioStreamPolicy.accepts(filename, title: title, episode: episode) {
                    reason = "Conflicting title, year or episode metadata; this source will not be played."
                }
                for text in [stream.title, stream.displayDetails].compactMap(\.self) {
                    for line in text.components(separatedBy: .newlines) where line.range(
                        of: #"(?i)s\d+e\d+|\d+x\d+|\btt\d{5,12}\b"#, options: .regularExpression,
                    ) != nil {
                        if !StremioStreamPolicy.accepts(line, title: title, episode: episode) {
                            reason = "The provider description identifies different or ambiguous media."
                        }
                    }
                }
                if let raw = stream.url, let path = URL(string: raw)?.lastPathComponent,
                   path.range(of: #"(?i)s\d+e\d+|\d+x\d+|\btt\d{5,12}\b"#, options: .regularExpression) != nil,
                   !StremioStreamPolicy.accepts(path, title: title, episode: episode)
                {
                    reason = "The stream URL identifies different or ambiguous media."
                }
                var link = "", direct = false
                if let raw = stream.url, AuthorizedSourceCandidate.validLink(raw) {
                    link = raw; direct = URL(string: raw)?.scheme?.lowercased() == "https"
                } else if let hash = stream.infoHash, hash.range(
                    of: #"^[a-fA-F0-9]{40}$"#,
                    options: .regularExpression,
                ) != nil {
                    var c = URLComponents(); c.scheme = "magnet"
                    c.queryItems = [URLQueryItem(name: "xt", value: "urn:btih:" + hash)]
                    if let filename {
                        c.queryItems?.append(URLQueryItem(name: "dn", value: filename))
                    }
                    if let fileIdx = stream.fileIdx {
                        c.queryItems?.append(URLQueryItem(
                            name: "so",
                            value: String(fileIdx),
                        ))
                    }
                    for tracker in stream.sources ?? [] where tracker.hasPrefix("tracker:") {
                        let raw = String(tracker.dropFirst("tracker:".count))
                        if let scheme = URL(string: raw)?.scheme, ["https", "udp"].contains(scheme) {
                            c.queryItems?.append(URLQueryItem(name: "tr", value: raw))
                        }
                    }
                    link = c.string ?? ""
                } else {
                    reason = reason ?? "No supported HTTPS, download link or v1 infoHash is available."
                }
                let key = link + "|" + (stream.fileIdx.map(String.init) ?? "default")
                if reason == nil, !seen.insert(key).inserted {
                    continue
                }
                let quality = AllDebridTitleMatcher.resolution([
                    stream.name,
                    stream.title,
                    stream.displayDetails,
                    filename,
                ].compactMap(\.self).joined(separator: " "))
                let name = title.displayTitle + (episode.map { " · S\($0.season_number) E\($0.episode_number)" } ?? "")
                    + " · \(quality > 0 ? String(quality) + "p" : "Original") · Source \(ordinal + 1)"
                entries.append(Entry(label: .init(
                    id: UUID().uuidString,
                    filename: name,
                    quality: quality,
                    audioHint: StremioAudioHint.reported(by: stream),
                    fileIndex: stream.fileIdx,
                    unsupportedReason: reason,
                ), link: link, direct: direct))
            }
        }
        let ranked = AllDebridTitleMatcher.ranked(entries.filter { !$0.submitted }.map { .stremio($0.label) })
        guard preferEnglish else { return ranked }
        return ranked.enumerated().sorted { lhs, rhs in
            guard case let .stremio(left) = lhs.element,
                  case let .stremio(right) = rhs.element else { return lhs.offset < rhs.offset }
            return left.audioHint.rawValue == right.audioHint.rawValue ? lhs.offset < rhs.offset : left.audioHint
                .rawValue < right.audioHint.rawValue
        }.map(\.element)
    }

    func hasPendingSource(snapshot: AllDebridLibrarySnapshot, title: TMDBTitle, episode: TMDBEpisode?) -> Bool {
        guard let identity = try? Self.identity(title: title, episode: episode),
              cachedIdentity == "\(title.kind):\(title.id):\(identity.id)" else { return false }
        return entries.contains { entry in
            guard entry.submitted, let id = entry.magnetID else { return false }
            if let magnet = snapshot.magnets.first(where: { $0.id == id }) {
                return magnet.isProcessing
            }
            // Allow the documented upload to appear in the next library snapshot without submitting more hashes.
            return entry.submittedAt.map { Date().timeIntervalSince($0) < 120 } ?? false
        }
    }

    func readySources(
        snapshot: AllDebridLibrarySnapshot,
        title: TMDBTitle,
        episode: TMDBEpisode?,
    ) -> [AllDebridTitleMatcher.Source] {
        guard let identity = try? Self.identity(title: title, episode: episode),
              cachedIdentity == "\(title.kind):\(title.id):\(identity.id)" else { return [] }
        return entries.flatMap { entry -> [AllDebridTitleMatcher.Source] in
            guard entry.submitted, let id = entry.magnetID,
                  snapshot.magnets.contains(where: { $0.id == id && $0.isReady }) else { return [] }
            // AllDebrid's file tree does not expose BEP torrent ordinals. Never treat its
            // flattened position as fileIdx or pick the largest video. Match actual media metadata.
            let files = snapshot.magnetFiles.filter { $0.magnetID == id && $0.isVideo }
            return files.filter { file in
                if episode == nil, files.count != 1 {
                    return false
                }
                return StremioStreamPolicy.readyFile(file, title: title, episode: episode)
            }.map(AllDebridTitleMatcher.Source.magnet)
        }
    }

    func isReadyDirect(_ label: StremioSourceLabel) -> Bool {
        entries.contains { $0.label == label && $0.direct && !$0.submitted }
    }

    func resolve(
        _ label: StremioSourceLabel,
        acquisition: CatalogSourceAcquisition?,
        title: TMDBTitle,
        episode: TMDBEpisode?,
    ) async throws -> URL {
        guard let index = entries.firstIndex(where: { $0.label == label }),
              !entries[index].submitted else { throw StremioError.playback }
        let entry = entries[index]
        guard entry.label.unsupportedReason == nil else { throw StremioError.unsupportedSource }
        try Task.checkCancellation()
        if entry.direct, let url = URL(string: entry.link) {
            do {
                let ready = try await client.playbackURL(url)
                try Task.checkCancellation()
                return ready
            } catch {
                if error.isCancellation {
                    throw CancellationError()
                }
                throw StremioError.playback
            }
        }
        guard let acquisition else { throw StremioError.unsupportedSource }
        do {
            if let existing = acquisition.submittedMagnetID(for: entry.link) {
                entries[index].magnetID = existing; entries[index].submitted = true; entries[index].submittedAt = Date()
                throw CatalogSourceResolver.Failure
                    .processing("Checking the already submitted torrent for the exact requested episode.")
            }
            try await acquisition.submitUserLink(entry.link, title: title, episode: episode)
            try Task.checkCancellation()
            guard entries.indices.contains(index), entries[index].label == label else { throw CancellationError() }
            entries[index].magnetID = acquisition.submittedMagnetID(for: entry.link)
            entries[index].submitted = true; entries[index].submittedAt = Date()
            throw CatalogSourceResolver.Failure
                .processing("Checking the authorized add-on source in AllDebrid. Availability refreshes automatically.")
        } catch {
            if error.isCancellation {
                throw CancellationError()
            }
            if case CatalogSourceResolver.Failure.processing = error {
                throw error
            }
            if AllDebridAPIClient.isAuthenticationOrRateLimit(error) {
                throw error
            }
            throw StremioError.playback
        }
    }
}
