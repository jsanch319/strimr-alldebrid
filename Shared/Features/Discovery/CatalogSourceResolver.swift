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
/// Optional authorized acquisition feeds this same matcher and player; unlocked URLs are never persisted.
@MainActor
@Observable
final class CatalogSourceResolver {
    struct Resolved {
        let source: AllDebridTitleMatcher.Source
        let url: URL
        let subtitles: [ExternalSubtitleTrack]
    }

    enum Failure: LocalizedError {
        case chooseEpisode, processing(String), noMatch(String), exhausted(String)
        var errorDescription: String? {
            switch self {
            case .chooseEpisode: "Choose a TV episode before starting playback."
            case let .processing(message), let .noMatch(message), let .exhausted(message): message
            }
        }
    }

    enum Availability: Equatable { case checking, ready, processing, missing, incomplete }
    private(set) var availability = Availability.checking
    private(set) var processingMagnets: [AllDebridMagnet] = []
    private var verifiedConnection = false
    private let acquisition: CatalogSourceAcquisition?
    var needsSourceSetup: Bool {
        acquisition?.needsSetup ?? true
    }

    private let client: any CatalogPlaybackClient
    private(set) var sources: [AllDebridTitleMatcher.Source] = []
    private(set) var files: [AllDebridMagnetFile] = []
    private(set) var warnings: [String] = []
    private var attempted = Set<String>()

    init(client: any CatalogPlaybackClient, acquisition: CatalogSourceAcquisition? = nil) {
        self.client = client; self.acquisition = acquisition
    }

    func addAuthorizedLink(_ link: String, title: TMDBTitle, episode: TMDBEpisode?) async throws {
        guard let acquisition else { throw Failure.noMatch("Connect AllDebrid before adding an authorized link.") }
        try await acquisition.submitUserLink(link, title: title, episode: episode)
    }

    func refresh(title: TMDBTitle, episode: TMDBEpisode?) async throws {
        sources = []; files = []; warnings = []; attempted = []; processingMagnets = []; availability = .checking
        guard title.kind != .tv || episode != nil else { throw Failure.chooseEpisode }
        if !verifiedConnection {
            _ = try await client.verifyConnection()
            verifiedConnection = true
        }
        let snapshot: AllDebridLibrarySnapshot
        do { snapshot = try await client.librarySnapshot() }
        catch {
            if AllDebridAPIClient.isAuthenticationOrRateLimit(error) {
                verifiedConnection = false
            }
            throw error
        }
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
        guard sources.isEmpty else { availability = .ready; return }
        processingMagnets = snapshot.magnets.filter {
            AllDebridTitleMatcher.matchesProcessingMagnet(title: title, episode: episode, magnet: $0)
        }
        let label = title.displayTitle + (episode.map { " S\($0.season_number) E\($0.episode_number)" } ?? "")
        if !processingMagnets.isEmpty {
            availability = .processing
            throw Failure
                .processing(
                    "\(label) is still processing in AllDebrid. Availability refreshes automatically while this screen is open.",
                )
        }
        availability = warnings.isEmpty ? .missing : .incomplete
        if !warnings.isEmpty {
            throw Failure.noMatch("The library check for \(label) was incomplete. " + warnings.joined(separator: " "))
        }
        if let acquisition {
            let imported = try await acquisition.discover(title: title, episode: episode, snapshot: snapshot)
            try Task.checkCancellation()
            sources = AllDebridTitleMatcher.sources(
                title: title,
                episode: episode,
                files: [],
                links: imported.filter { AuthorizedSourceCandidate.matchesFile(
                    $0.filename,
                    title: title,
                    episode: episode,
                ) },
            )
            if !sources.isEmpty {
                availability = .ready; return
            }
            if acquisition.isProcessing {
                availability = .processing
                throw Failure
                    .processing(
                        "An authorized source was submitted to AllDebrid. Waiting for the exact matching file; availability refreshes automatically.",
                    )
            }
        }
        throw Failure
            .noMatch(
                "\(label) is not available as a matching playable file in your connected AllDebrid library. No playable authorized source was found. Configure an authorized source provider or add your own authorized link. AllDebrid does not discover titles by itself.",
            )
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
        guard sources.contains(source)
        else {
            throw Failure.noMatch("This file is no longer in the current matching source list. Refresh availability.")
        }
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
