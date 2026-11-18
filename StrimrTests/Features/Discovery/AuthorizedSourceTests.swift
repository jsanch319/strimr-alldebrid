import Foundation
@testable import Strimr
import Testing

@MainActor
struct AuthorizedSourceTests {
    let movie = TMDBTitle.reference(id: 1, kind: .movie, title: "Dune", year: 2021)
    let magnet = "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&dn=Dune.2021"
    var empty: AllDebridLibrarySnapshot {
        .init(savedLinks: [], magnets: [], readyMagnetCount: 0, magnetFiles: [])
    }

    func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AuthorizedSourceTests." + UUID().uuidString)!
    }

    func candidate(
        _ link: String,
        id: Int = 1,
        year: Int = 2021,
        filename: String = "Dune.2021.1080p.mkv",
    ) -> AuthorizedSourceCandidate {
        .init(
            tmdbID: id,
            kind: "movie",
            year: year,
            season: nil,
            episode: nil,
            filename: filename,
            link: link,
            authorized: true,
        )
    }

    func file(_ filename: String) -> AllDebridMagnetFile {
        .init(
            id: filename,
            magnetID: "42",
            filename: filename,
            fullPath: filename,
            size: 100,
            link: "https://files.test/ready",
        )
    }

    @Test func `existing library wins without searching or submitting`() async throws {
        let client = AcquisitionFixture(files: [file("Dune.2021.mkv")])
        let provider = ProviderFixture(candidates: [candidate(magnet)])
        let acquisition = CatalogSourceAcquisition(
            client: client,
            providers: [provider],
            account: "account",
            defaults: defaults(),
        )
        let resolver = CatalogSourceResolver(client: client, acquisition: acquisition)
        try await resolver.refresh(title: movie, episode: nil)
        #expect(resolver.sources.count == 1)
        #expect(await provider.calls == 0)
        #expect(await client.uploads == 0)
    }

    @Test func `missing provider exposes setup and never acquires`() async throws {
        let client = AcquisitionFixture()
        let acquisition = CatalogSourceAcquisition(client: client, providers: [], account: "a", defaults: defaults())
        let resolver = CatalogSourceResolver(client: client, acquisition: acquisition)
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.refresh(
            title: movie,
            episode: nil,
        ) }
        #expect(resolver.needsSourceSetup)
        #expect(resolver.availability == .missing)
        #expect(await client.uploads == 0)
    }

    @Test func `wrong identity year and filename are rejected before acquisition`() async throws {
        let client = AcquisitionFixture()
        let provider = ProviderFixture(candidates: [
            candidate(magnet, id: 2),
            candidate(magnet, year: 1984),
            candidate(magnet, filename: "Other.2021.mkv"),
        ])
        let acquisition = CatalogSourceAcquisition(
            client: client,
            providers: [provider],
            account: "a",
            defaults: defaults(),
        )
        #expect(try await acquisition.discover(title: movie, episode: nil, snapshot: empty).isEmpty)
        #expect(await client.uploads == 0)
    }

    @Test func `magnet submission polls then opens only correct ready file`() async throws {
        let client = AcquisitionFixture()
        let provider = ProviderFixture(candidates: [candidate(magnet)])
        let acquisition = CatalogSourceAcquisition(
            client: client,
            providers: [provider],
            account: "a",
            defaults: defaults(),
        )
        let resolver = CatalogSourceResolver(client: client, acquisition: acquisition)
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.refresh(
            title: movie,
            episode: nil,
        ) }
        #expect(resolver.availability == .processing)
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.refresh(
            title: movie,
            episode: nil,
        ) }
        #expect(await client.uploads == 1)
        #expect(await provider.calls == 1)
        await client.setFiles([file("Dune.1984.mkv"), file("Dune.2021.mkv")])
        try await resolver.refresh(title: movie, episode: nil)
        #expect(try await resolver.resolveNext().source.filename == "Dune.2021.mkv")
    }

    @Test func `submission receipts survive resolver restart and isolate accounts`() async throws {
        let d = defaults(), client = AcquisitionFixture(), provider = ProviderFixture(candidates: [candidate(magnet)])
        let first = CatalogSourceAcquisition(client: client, providers: [provider], account: "a", defaults: d)
        _ = try await first.discover(title: movie, episode: nil, snapshot: empty)
        let restarted = CatalogSourceAcquisition(client: client, providers: [provider], account: "a", defaults: d)
        _ = try await restarted.discover(title: movie, episode: nil, snapshot: empty)
        #expect(await client.uploads == 1)
        let other = CatalogSourceAcquisition(client: client, providers: [provider], account: "b", defaults: d)
        _ = try await other.discover(title: movie, episode: nil, snapshot: empty)
        #expect(await client.uploads == 2)
        let stored = d.dictionaryRepresentation().filter { $0.key.hasPrefix("catalog.acquisition.") }
        #expect(!String(describing: stored).contains(magnet))
    }

    @Test func `magnet hash deduplicates display-name and tracker variations`() async throws {
        let client = AcquisitionFixture()
        let shared = CatalogSourceAcquisition(client: client, providers: [], account: "a", defaults: defaults())
        try await shared.submitUserLink(magnet, title: movie, episode: nil)
        await #expect(throws: CatalogSourceResolver.Failure.self) {
            try await shared.submitUserLink(magnet + "&tr=https://tracker.test", title: movie, episode: nil)
        }
        #expect(await client.uploads == 1)
    }

    @Test func `ambiguous upload failure is never automatically resubmitted`() async throws {
        let client = AcquisitionFixture(failUpload: true), provider = ProviderFixture(candidates: [candidate(magnet)])
        let acquisition = CatalogSourceAcquisition(
            client: client,
            providers: [provider],
            account: "a",
            defaults: defaults(),
        )
        _ = try await acquisition.discover(title: movie, episode: nil, snapshot: empty)
        _ = try await acquisition.discover(title: movie, episode: nil, snapshot: empty)
        #expect(await client.uploads == 1)
    }

    @Test func `direct link actual filename wins over provider label`() async throws {
        let client = AcquisitionFixture(importName: "Other.2021.mkv")
        let acquisition = CatalogSourceAcquisition(
            client: client,
            providers: [ProviderFixture(candidates: [candidate("https://host.test/file")])],
            account: "a",
            defaults: defaults(),
        )
        #expect(try await acquisition.discover(title: movie, episode: nil, snapshot: empty).isEmpty)
        await #expect(throws: CatalogSourceResolver.Failure.self) {
            try await acquisition.submitUserLink("https://host.test/file", title: movie, episode: nil)
        }
        #expect(!AuthorizedSourceCandidate.matchesFile("Dune.mkv", title: movie, episode: nil))
    }

    @Test func `manual delayed link becomes ready through same resolver`() async throws {
        let client = AcquisitionFixture(delayed: true)
        let acquisition = CatalogSourceAcquisition(client: client, providers: [], account: "a", defaults: defaults())
        let resolver = CatalogSourceResolver(client: client, acquisition: acquisition)
        try await resolver.addAuthorizedLink("https://host.test/file", title: movie, episode: nil)
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.refresh(
            title: movie,
            episode: nil,
        ) }
        #expect(resolver.availability == .processing)
        await client.finishDelay()
        try await resolver.refresh(title: movie, episode: nil)
        #expect(try await resolver.resolveNext().source.filename == "Dune.2021.mkv")
    }

    @Test func `TV candidates require exact season episode and real filename`() throws {
        let show = TMDBTitle.reference(id: 2, kind: .tv, title: "Series", year: 2022)
        let episode = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":20,"name":"Two","season_number":1,"episode_number":2}"#.utf8),
        )
        let wrong = AuthorizedSourceCandidate(
            tmdbID: 2,
            kind: "tv",
            year: 2022,
            season: 1,
            episode: 1,
            filename: "Series.S01E02.mkv",
            link: magnet,
            authorized: true,
        )
        #expect(!wrong.matches(show, episode: episode))
        #expect(!AuthorizedSourceCandidate.matchesFile("Series.S01E01.mkv", title: show, episode: episode))
        #expect(AuthorizedSourceCandidate.matchesFile("Series.S01E02.mkv", title: show, episode: episode))
        #expect(!AuthorizedSourceCandidate.matchesFile("Series.S01E02E03.mkv", title: show, episode: episode))
    }

    @Test func `provider endpoint rejects credentials insecure schemes and token queries`() {
        for raw in [
            "http://host.test/search",
            "https://user:secret@host.test/search",
            "https://host.test/search?token=secret",
            "file:///tmp/test",
        ] {
            #expect(HTTPSAuthorizedSourceProvider.endpoint(raw) == nil)
        }
        #expect(AuthorizedSourceSettings.providers("https://host.test/search\nhttps://host.test/search").count == 1)
        #expect(!AuthorizedSourceCandidate.validLink("magnet:?xt=bad"))
    }
}

private actor ProviderFixture: AuthorizedSourceProvider {
    let candidates: [AuthorizedSourceCandidate]
    private(set) var calls = 0
    init(candidates: [AuthorizedSourceCandidate]) {
        self.candidates = candidates
    }

    func search(
        title _: TMDBTitle,
        episode _: TMDBEpisode?,
    ) -> [AuthorizedSourceCandidate] {
        calls += 1; return candidates
    }
}

private actor AcquisitionFixture: CatalogPlaybackClient, CatalogAcquisitionClient {
    var files: [AllDebridMagnetFile]
    let failUpload: Bool
    let importName: String
    let delayed: Bool
    var delayFinished = false
    private(set) var uploads = 0
    init(
        files: [AllDebridMagnetFile] = [],
        failUpload: Bool = false,
        importName: String = "Dune.2021.mkv",
        delayed: Bool = false,
    ) {
        self.files = files; self.failUpload = failUpload; self.importName = importName; self.delayed = delayed
    }

    func setFiles(_ files: [AllDebridMagnetFile]) {
        self.files = files
    }

    func finishDelay() {
        delayFinished = true
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

    func uploadMagnet(_: String) throws -> String {
        uploads +=
            1; if failUpload
        {
            throw URLError(.timedOut)
        }; return "42"
    }

    func importDownloadLink(_ link: String) -> AllDebridLinkImport {
        delayed ? .delayed(id: "7", filename: importName) : .ready(.init(id: link, filename: importName, link: link))
    }

    func delayedDownload(id _: String, original: String, filename: String) -> AllDebridSavedLink? {
        delayFinished ? .init(id: original, filename: filename, link: original) : nil
    }

    func resolvePlaybackURL(_: String, filename _: String) -> AllDebridPlaybackResolution {
        .init(
            url: URL(string: "https://media.test/video.mkv")!,
            statusCode: 200,
            contentType: "video/x-matroska",
            followedRedirect: false,
        )
    }
}
