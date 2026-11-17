import AetherEngine
import Foundation
import Observation

nonisolated protocol CatalogPlaybackClient: Sendable {
    func verifyConnection() async throws -> String?
    func librarySnapshot() async throws -> AllDebridLibrarySnapshot
    func resolvePlaybackURL(_ link: String, filename: String) async throws -> AllDebridPlaybackResolution
}

extension AllDebridAPIClient: CatalogPlaybackClient {}

/// One refreshed account-library snapshot and a bounded, quality-ordered fallback queue.
/// No title acquisition, unlocked-URL persistence, or separate playback/progress implementation.
@MainActor
@Observable
final class CatalogSourceResolver {
    struct Resolved {
        let source: AllDebridTitleMatcher.Source
        let url: URL
        let subtitles: [ExternalSubtitleTrack]
    }

    enum Failure: LocalizedError {
        case chooseEpisode, noMatch(String), exhausted(String)
        var errorDescription: String? {
            switch self {
            case .chooseEpisode: "Choose a TV episode before starting playback."
            case let .noMatch(message), let .exhausted(message): message
            }
        }
    }

    private let client: any CatalogPlaybackClient
    private(set) var sources: [AllDebridTitleMatcher.Source] = []
    private(set) var files: [AllDebridMagnetFile] = []
    private(set) var warnings: [String] = []
    private var attempted = Set<String>()

    init(client: any CatalogPlaybackClient) {
        self.client = client
    }

    func refresh(title: TMDBTitle, episode: TMDBEpisode?) async throws {
        sources = []; files = []; warnings = []; attempted = []
        guard title.kind != .tv || episode != nil else { throw Failure.chooseEpisode }
        _ = try await client.verifyConnection()
        let snapshot = try await client.librarySnapshot()
        try Task.checkCancellation()
        files = snapshot.magnetFiles
        warnings = snapshot.warnings
        let names = Dictionary(snapshot.magnets.map { ($0.id, $0.filename) }, uniquingKeysWith: { first, _ in first })
        sources = AllDebridTitleMatcher.sources(
            title: title,
            episode: episode,
            files: files,
            links: snapshot.savedLinks,
            magnetNames: names,
        )
        guard !sources.isEmpty else {
            let pending = snapshot.magnets.count - snapshot.readyMagnetCount
            let label = title.displayTitle + (episode.map { " S\($0.season_number) E\($0.episode_number)" } ?? "")
            var message = "No matching playable file for \(label) was found in your connected AllDebrid library."
            if pending > 0 {
                message += " \(pending) magnet(s) are still processing. Refresh after they are ready."
            } else {
                message +=
                    " Checked \(files.filter(\.isVideo).count) ready video file(s) and \(snapshot.savedLinks.filter(\.isVideo).count) saved video link(s)."
            }
            if !warnings
                .isEmpty
            {
                message += " The library refresh was incomplete. " + warnings.joined(separator: " ")
            } else {
                message +=
                    " Make sure the file or its folder identifies the correct title/year and, for TV, season and episode."
            }
            throw Failure.noMatch(message)
        }
    }

    func resolveNext() async throws -> Resolved {
        var lastError: Error?
        for source in sources where !attempted.contains(source.link) {
            try Task.checkCancellation()
            attempted.insert(source.link)
            do { return try await resolve(source) }
            catch {
                if error.isCancellation || AllDebridAPIClient.isAuthenticationOrRateLimit(error) {
                    throw error
                }
                lastError = error
            }
        }
        throw Failure
            .exhausted("None of the matching files could be played. Try Refresh or Select Source. " +
                (lastError?.localizedDescription ?? "The available sources failed during playback."))
    }

    func resolveSelected(_ source: AllDebridTitleMatcher.Source) async throws -> Resolved {
        try Task.checkCancellation()
        return try await resolve(source)
    }

    private func resolve(_ source: AllDebridTitleMatcher.Source) async throws -> Resolved {
        let result = try await client.resolvePlaybackURL(source.link, filename: source.filename)
        try Task.checkCancellation()
        let subtitles: [ExternalSubtitleTrack] = if case let .magnet(file) = source {
            AllDebridSubtitleMatcher.externalTracks(
                for: file,
                in: files,
            )
        } else {
            []
        }
        return Resolved(source: source, url: result.url, subtitles: subtitles)
    }
}
