import Foundation
@testable import Strimr
import Testing

@MainActor
struct StremioTests {
    let movie = try! JSONDecoder().decode(
        TMDBTitle.self,
        from: Data(
            #"{"id":1,"media_type":"movie","title":"Dune","release_date":"2021-10-22","external_ids":{"imdb_id":"tt1160419"}}"#
                .utf8,
        ),
    )
    let show = try! JSONDecoder().decode(
        TMDBTitle.self,
        from: Data(
            #"{"id":2,"media_type":"tv","name":"Series","first_air_date":"2022-01-01","external_ids":{"imdb_id":"tt1234567"}}"#
                .utf8,
        ),
    )
    let episode = try! JSONDecoder().decode(
        TMDBEpisode.self,
        from: Data(#"{"id":20,"name":"Two","season_number":1,"episode_number":2}"#.utf8),
    )
    let configuration = try! StremioConfiguration(
        url: "https://addon.test/fixtureOnly/manifest.json?token=fixtureOnly",
        authorized: true,
    )

    func streams(_ raw: String) -> [StremioStream] {
        try! JSONDecoder().decode(
            [StremioStream].self,
            from: Data(raw.utf8),
        )
    }

    func file(_ filename: String) -> AllDebridMagnetFile {
        .init(
            id: filename,
            magnetID: "42",
            filename: filename,
            fullPath: filename,
            size: 100,
            link: "https://library.test/file",
        )
    }

    func service(_ client: AddonFixture, store: AddonMemoryStore? = nil) -> StremioPlaybackSources {
        .init(client: client, store: store ?? AddonMemoryStore(configuration: configuration))
    }

    @Test func `manifest URLs normalize protocol and preserve private path and query in stream requests`() throws {
        let c = try StremioConfiguration(
            url: "stremio://addon.test/ad%3DfixtureOnly/manifest.json?token=fixtureOnly",
            authorized: true,
        )
        let url = c.streamURL(type: "series", id: "tt1234567:1:2")
        #expect(url.scheme == "https")
        #expect(url.path == "/ad=fixtureOnly/stream/series/tt1234567:1:2.json")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "fixtureOnly")
        for raw in [
            "http://addon.test/manifest.json",
            "https://user:password@addon.test/manifest.json",
            "https://addon.test/configure",
            "file:///manifest.json",
        ] {
            #expect(throws: StremioError.self) { try StremioConfiguration(url: raw, authorized: true) }
        }
    }

    @Test func `configuration and stream descriptions redact credentials and configured name remains useful`() {
        #expect(!String(describing: configuration).contains("fixtureOnly"))
        #expect(!String(reflecting: configuration).contains("addon.test"))
        #expect(configuration.safeName("Torrentio") == "Torrentio")
        #expect(!configuration.safeName("fixtureOnly").contains("fixtureOnly"))
        #expect(!configuration.safeName(configuration.manifestURL.absoluteString).contains("fixtureOnly"))
        let value = streams(#"[{"name":"4K","url":"https://cdn.test/fixtureOnly/movie.mkv"}]"#)[0]
        #expect(!String(reflecting: value).contains("fixtureOnly"))
    }

    @Test func `movie and TV stream identity is exact IMDb with season and episode`() throws {
        #expect(try StremioPlaybackSources.identity(title: movie, episode: nil).id == "tt1160419")
        let tv = try StremioPlaybackSources.identity(title: show, episode: episode)
        #expect(tv.type == "series")
        #expect(tv.id == "tt1234567:1:2")
        #expect(throws: StremioError.self) { try StremioPlaybackSources.identity(
            title: .reference(id: 1, kind: .movie, title: "Dune"),
            episode: nil,
        ) }
        #expect(throws: CatalogSourceResolver.Failure.self) { try StremioPlaybackSources.identity(
            title: show,
            episode: nil,
        ) }
    }

    @Test func `existing library file avoids even reading add-on configuration`() async throws {
        let client = AddonFixture(streams: [])
        let store = AddonMemoryStore(configuration: configuration)
        let library = AddonLibrary(files: [file("Dune.2021.mkv")])
        let resolver = CatalogSourceResolver(client: library, stremio: service(client, store: store))
        try await resolver.refresh(title: movie, episode: nil)
        #expect(store.loads == 0)
        #expect(await client.searches.isEmpty)
        #expect(resolver.sources.count == 1)
    }

    @Test func `missing add-on and empty streams have clear no-source outcomes`() async throws {
        let client = AddonFixture(streams: [])
        let noConfig = service(client, store: AddonMemoryStore(configuration: nil))
        #expect(try await noConfig.discover(title: movie, episode: nil).isEmpty)
        #expect(!noConfig.configured)
        let configured = service(client)
        #expect(try await configured.discover(title: movie, episode: nil).isEmpty)
        #expect(configured.configured)
        let resolver = CatalogSourceResolver(client: AddonLibrary(), stremio: configured)
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.refresh(
            title: movie,
            episode: nil,
        ) }
        #expect(resolver.availability == .missing)
    }

    @Test func `wrong filename episode and combined episodes never enter source queue`() async throws {
        let client =
            AddonFixture(
                streams: streams(
                    #"[{"url":"https://cdn.test/wrong.mkv","behaviorHints":{"filename":"Series.S01E01.mkv"}},{"url":"https://cdn.test/multi.mkv","behaviorHints":{"filename":"Series.S01E02E03.mkv"}},{"url":"https://cdn.test/right.mkv","behaviorHints":{"filename":"Series.S01E02.mkv"}}]"#,
                ),
            )
        let sources = try await service(client).discover(title: show, episode: episode)
        #expect(sources.count == 1)
        #expect(await client.searches == ["series/tt1234567:1:2"])
    }

    @Test func `ready HTTPS streams rank by quality and fallback without another library unlock`() async throws {
        let client = AddonFixture(
            streams: streams(
                #"[{"name":"720p","url":"https://cdn.test/720.mkv"},{"name":"4K","url":"https://cdn.test/4k.mkv"},{"name":"1080p","url":"https://cdn.test/1080.mkv"}]"#,
            ),
            fail4K: true,
        )
        let library = AddonLibrary()
        let upload = AddonAcquisition()
        let acquisition = try CatalogSourceAcquisition(
            client: upload,
            providers: [],
            account: "fixture",
            defaults: #require(UserDefaults(suiteName: UUID().uuidString)),
        )
        let resolver = CatalogSourceResolver(client: library, acquisition: acquisition, stremio: service(client))
        try await resolver.refresh(title: movie, episode: nil)
        #expect(resolver.sources.map { AllDebridTitleMatcher.resolution($0.filename) } == [2160, 1080, 720])
        let first = try await resolver.resolveNext()
        #expect(first.url.path == "/1080.mkv")
        let next = try await resolver.resolveNext() // engine failure advances rather than retrying the previous stream
        #expect(next.url.path == "/720.mkv")
        #expect(await client.played.map(\.path) == ["/4k.mkv", "/1080.mkv", "/720.mkv"])
        #expect(await library.unlocks == 0)
        #expect(await upload.imports == 0) // Never forward a failed private HTTPS stream URL to another provider.
    }

    @Test func `manual selection uses opaque identity and never exposes signed URL`() async throws {
        let client =
            AddonFixture(
                streams: streams(
                    #"[{"name":"1080p fixtureOnly","title":"https://config.test/fixtureOnly","url":"https://cdn.test/movie.mkv?key=fixtureOnly"}]"#,
                ),
            )
        let resolver = CatalogSourceResolver(client: AddonLibrary(), stremio: service(client))
        try await resolver.refresh(title: movie, episode: nil)
        let source = try #require(resolver.sources.first)
        #expect(!source.filename.contains("fixtureOnly"))
        #expect(!source.link.contains("fixtureOnly"))
        #expect(try await resolver.resolveSelected(source).url.host == "cdn.test")
    }

    @Test func `stream metadata is cached in memory and identity changes invalidate it`() async throws {
        let client = AddonFixture(streams: streams(#"[{"url":"https://cdn.test/file.mkv"}]"#))
        let addon = service(client)
        let first = try await addon.discover(title: movie, episode: nil)
        #expect(try await addon.discover(title: movie, episode: nil) == first)
        #expect(await client.searches.count == 1)
        _ = try await addon.discover(title: show, episode: episode)
        #expect(await client.searches.count == 2)
    }

    @Test func `cancelling active discovery cannot publish sources or start playback`() async throws {
        let client = AddonFixture(streams: streams(#"[{"url":"https://cdn.test/file.mkv"}]"#), waits: true)
        let resolver = CatalogSourceResolver(client: AddonLibrary(), stremio: service(client))
        let task = Task { try await resolver.refresh(title: movie, episode: nil) }
        for _ in 0 ..< 100 {
            if await client.started {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await client.started)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(resolver.sources.isEmpty)
        #expect(await client.played.isEmpty)
    }

    @Test func `authorized magnet uses existing AllDebrid acquisition and exact ready file selection`() async throws {
        let client =
            AddonFixture(
                streams: streams(
                    #"[{"name":"1080p","infoHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileIdx":0,"behaviorHints":{"filename":"Dune.2021.1080p.mkv"}}]"#,
                ),
            )
        let library = AddonLibrary(), upload = AddonAcquisition()
        let acquisition = try CatalogSourceAcquisition(
            client: upload,
            providers: [],
            account: "fixture",
            defaults: #require(UserDefaults(suiteName: UUID().uuidString)),
        )
        let resolver = CatalogSourceResolver(client: library, acquisition: acquisition, stremio: service(client))
        try await resolver.refresh(title: movie, episode: nil)
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.resolveNext() }
        #expect(resolver.availability == .processing)
        #expect(await upload.uploads == 1)
        await library.setFiles([file("Dune.1984.mkv"), file("Dune.2021.1080p.mkv")])
        try await resolver.refresh(title: movie, episode: nil)
        #expect(try await resolver.resolveNext().source.filename == "Dune.2021.1080p.mkv")
    }
}

@MainActor
private final class AddonMemoryStore: StremioConfigurationStorage {
    var configuration: StremioConfiguration?
    var loads = 0
    init(configuration: StremioConfiguration?) {
        self.configuration = configuration
    }

    func load() -> StremioConfiguration? {
        loads += 1; return configuration
    }

    func save(_ configuration: StremioConfiguration) {
        self.configuration = configuration
    }

    func delete() {
        configuration = nil
    }
}

private actor AddonFixture: StremioClientProtocol {
    let values: [StremioStream]
    let fail4K: Bool
    let waits: Bool
    private(set) var searches: [String] = []
    private(set) var played: [URL] = []
    private(set) var started = false
    init(streams: [StremioStream], fail4K: Bool = false, waits: Bool = false) {
        values = streams; self.fail4K = fail4K; self.waits = waits
    }

    func manifest(_: StremioConfiguration) throws -> StremioManifest {
        try JSONDecoder().decode(
            StremioManifest.self,
            from: Data(
                #"{"id":"fixture","version":"1.0.0","name":"Torrentio","types":["movie","series"],"resources":["stream"]}"#
                    .utf8,
            ),
        )
    }

    func streams(_: StremioConfiguration, type: String, id: String) async throws -> [StremioStream] {
        searches.append(type + "/" + id); started = true
        if waits {
            try await Task.sleep(for: .seconds(60))
        }
        return values
    }

    func playbackURL(_ url: URL) throws -> URL {
        played.append(url)
        if fail4K, url.path.contains("4k") {
            throw StremioError.playback
        }
        return url
    }
}

private actor AddonLibrary: CatalogPlaybackClient {
    var files: [AllDebridMagnetFile]
    private(set) var unlocks = 0
    init(files: [AllDebridMagnetFile] = []) {
        self.files = files
    }

    func setFiles(_ files: [AllDebridMagnetFile]) {
        self.files = files
    }

    func verifyConnection() -> String? {
        "fixture"
    }

    func librarySnapshot() -> AllDebridLibrarySnapshot {
        .init(
            savedLinks: [],
            magnets: [],
            readyMagnetCount: 0,
            magnetFiles: files,
        )
    }

    func resolvePlaybackURL(_: String, filename _: String) -> AllDebridPlaybackResolution {
        unlocks += 1
        return .init(
            url: URL(string: "https://library.test/video.mkv")!,
            statusCode: 200,
            contentType: "video/x-matroska",
            followedRedirect: false,
        )
    }
}

private actor AddonAcquisition: CatalogAcquisitionClient {
    private(set) var uploads = 0
    private(set) var imports = 0
    func uploadMagnet(_: String) -> String {
        uploads += 1; return "42"
    }

    func importDownloadLink(_: String) throws -> AllDebridLinkImport {
        imports += 1
        throw StremioError.unsupportedSource
    }

    func delayedDownload(id _: String, original _: String, filename _: String) -> AllDebridSavedLink? {
        nil
    }
}
