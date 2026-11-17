import Foundation
@testable import Strimr
import Testing

@MainActor
struct CatalogAutoPlayTests {
    private let movie = TMDBTitle.reference(id: 1, kind: .movie, title: "Dune", year: 2021)

    private func file(_ name: String, path: String? = nil, magnet: String = "m") -> AllDebridMagnetFile {
        .init(
            id: name,
            magnetID: magnet,
            filename: name,
            fullPath: path ?? name,
            size: 100,
            link: "https://files.test/" + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!,
        )
    }

    @Test func `auto play defaults on migrates old settings and persists off`() throws {
        let legacy = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        #expect(legacy.allDebridAutoPlay)
        let defaults = TestDefaults.make()
        let manager = SettingsManager(userDefaults: defaults)
        #expect(manager.playback.allDebridAutoPlay)
        manager.updatePlayback { $0.allDebridAutoPlay = false }
        #expect(!SettingsManager(userDefaults: defaults).playback.allDebridAutoPlay)
    }

    @Test func `movie matches underscore tags original titles and verified folder names without matching remakes`() {
        #expect(AllDebridTitleMatcher.matches(title: movie, episode: nil, filename: "Dune_2021_2160p_WEB-DL.mkv"))
        #expect(AllDebridTitleMatcher.matches(
            title: movie,
            episode: nil,
            filename: "video.mkv",
            context: "Movies/Dune (2021)",
        ))
        #expect(!AllDebridTitleMatcher.matches(
            title: movie,
            episode: nil,
            filename: "Dune.1984.1080p.mkv",
            context: "Dune 2021",
        ))
        #expect(!AllDebridTitleMatcher.matches(
            title: movie,
            episode: nil,
            filename: "sample.mkv",
            context: "Dune 2021",
        ))
        #expect(!AllDebridTitleMatcher.matches(
            title: movie,
            episode: nil,
            filename: "Another.Movie.2021.mkv",
            context: "Dune 2021",
        ))
        let spider = TMDBTitle.reference(id: 2, kind: .movie, title: "Spider-Man")
        #expect(AllDebridTitleMatcher.matches(title: spider, episode: nil, filename: "Spider-Man.mkv"))
        var translated = TMDBTitle.reference(id: 3, kind: .movie, title: "Localized Name")
        translated.original_title = "Original Name"
        #expect(AllDebridTitleMatcher.matches(title: translated, episode: nil, filename: "Original.Name.1080p.mkv"))
    }

    @Test func `TV identifies season folders and episode only files and rejects ambiguous episodes`() throws {
        let show = TMDBTitle.reference(id: 9, kind: .tv, title: "Example Show")
        let ep = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":2,"season_number":2,"episode_number":3,"name":"Third"}"#.utf8),
        )
        for name in ["E03.mkv", "episode03.mp4", "03 - Third.mkv", "S02E03.mkv", "Example_Show_S02E03_1080p.mkv"] {
            #expect(AllDebridTitleMatcher.matches(
                title: show,
                episode: ep,
                filename: name,
                context: "Example Show/Season 2",
            ))
        }
        for name in [
            "Example.Show.S01E03.mkv",
            "Example.Show.S02E03E04.mkv",
            "Example.Show.S02E03-E04.mkv",
            "Other.Show.S02E03.mkv",
        ] {
            #expect(!AllDebridTitleMatcher.matches(
                title: show,
                episode: ep,
                filename: name,
                context: "Example Show/Season 2",
            ))
        }
        #expect(!AllDebridTitleMatcher.matches(title: show, episode: ep, filename: "E03.mkv", context: "Example Show"))
        #expect(!AllDebridTitleMatcher.matches(title: show, episode: nil, filename: "Example.Show.S02E03.mkv"))
    }

    @Test func `resolution order preserves every manual variant including shared links`() {
        let files = [file("Dune.2021.720p.mkv"), file("Dune.2021.2160p.mkv"), file("Dune.2021.1080p.mkv")]
        let duplicate = AllDebridSavedLink(id: "duplicate", filename: files[1].filename, link: files[1].link)
        let sources = AllDebridTitleMatcher.sources(title: movie, episode: nil, files: files, links: [duplicate])
        #expect(sources.map { AllDebridTitleMatcher.resolution($0.filename) } == [2160, 2160, 1080, 720])
    }

    @Test func `failed 4K resolution falls back then engine failure advances to 720 without retrying failed files`(
    ) async throws {
        let files = [file("Dune.2021.720p.mkv"), file("Dune.2021.2160p.mkv"), file("Dune.2021.1080p.mkv")]
        let duplicate = AllDebridMagnetFile(
            id: "duplicate",
            magnetID: "m",
            filename: files[1].filename,
            fullPath: files[1].fullPath,
            size: 100,
            link: files[1].link,
        )
        let client = AutoPlayClient(files: files + [duplicate], failing: [files[1].link])
        let resolver = CatalogSourceResolver(client: client)
        try await resolver.refresh(title: movie, episode: nil)
        let first = try await resolver.resolveNext()
        #expect(first.source.filename.contains("1080p"))
        // Same queue is used after the native engine reports a startup/read failure.
        let second = try await resolver.resolveNext()
        #expect(second.source.filename.contains("720p"))
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.resolveNext() }
        #expect(await client.requested().count == 3)
        try await resolver.refresh(title: movie, episode: nil)
        #expect(try await resolver.resolveNext().source.filename.contains("1080p"))
    }

    @Test(arguments: [AllDebridAPIClient.APIError.invalidAPIKey, .httpStatus(429)])
    func `authorization and rate limits during resolution do not try every file`(_ failure: AllDebridAPIClient
        .APIError) async throws
    {
        let client = AutoPlayClient(
            files: [file("Dune.2021.2160p.mkv"), file("Dune.2021.1080p.mkv")],
            resolutionError: failure,
        )
        let resolver = CatalogSourceResolver(client: client)
        try await resolver.refresh(title: movie, episode: nil)
        await #expect(throws: failure) { try await resolver.resolveNext() }
        #expect(await client.requested().count == 1)
    }

    @Test func `authentication failure stops fallback and a refresh replaces stale sources`() async throws {
        let files = [file("Dune.2021.2160p.mkv"), file("Dune.2021.1080p.mkv")]
        let client = AutoPlayClient(files: files, unauthorized: true)
        let resolver = CatalogSourceResolver(client: client)
        await #expect(throws: AllDebridAPIClient.APIError.invalidAPIKey) { try await resolver.refresh(
            title: movie,
            episode: nil,
        ) }
        #expect(resolver.sources.isEmpty)
        await client.authorize()
        try await resolver.refresh(title: movie, episode: nil)
        #expect(resolver.sources.count == 2)
        await client.empty()
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.refresh(
            title: movie,
            episode: nil,
        ) }
        #expect(resolver.sources.isEmpty)
    }
}

private actor AutoPlayClient: CatalogPlaybackClient {
    var files: [AllDebridMagnetFile]
    let failing: Set<String>
    var unauthorized: Bool
    var requests: [String] = []
    let resolutionError: AllDebridAPIClient.APIError?
    init(
        files: [AllDebridMagnetFile],
        failing: Set<String> = [],
        unauthorized: Bool = false,
        resolutionError: AllDebridAPIClient.APIError? = nil,
    ) {
        self.files = files; self.failing = failing; self.unauthorized = unauthorized
        self.resolutionError = resolutionError
    }

    func verifyConnection() async throws -> String? {
        if unauthorized {
            throw AllDebridAPIClient.APIError.invalidAPIKey
        }
        return "fixture"
    }

    func librarySnapshot() async throws -> AllDebridLibrarySnapshot {
        .init(savedLinks: [], magnets: [], readyMagnetCount: 0, magnetFiles: files)
    }

    func resolvePlaybackURL(_ link: String, filename _: String) async throws -> AllDebridPlaybackResolution {
        requests.append(link)
        if let resolutionError {
            throw resolutionError
        }
        if failing.contains(link) {
            throw AllDebridAPIClient.APIError.playbackHTTPStatus(503)
        }
        return .init(
            url: URL(string: "https://media.test/video.mkv")!,
            statusCode: 200,
            contentType: "video/x-matroska",
            followedRedirect: false,
        )
    }

    func requested() -> [String] {
        requests
    }

    func authorize() {
        unauthorized = false
    }

    func empty() {
        files = []
    }
}
