import Foundation
@testable import Strimr
import Testing

@MainActor
struct CatalogAvailabilityTests {
    private let movie = TMDBTitle.reference(id: 1, kind: .movie, title: "Dune", year: 2021)
    private func pending(_ name: String, code: Int = 1) -> AllDebridMagnet {
        .init(id: name, filename: name, size: 100, status: "Downloading", statusCode: code)
    }

    private func file(_ name: String) -> AllDebridMagnetFile {
        .init(id: name, magnetID: "m", filename: name, fullPath: name, size: 100, link: "https://files.test/" + name)
    }

    private func snapshot(_ magnets: [AllDebridMagnet], files: [AllDebridMagnetFile] = []) -> AllDebridLibrarySnapshot {
        .init(savedLinks: [], magnets: magnets, readyMagnetCount: magnets.filter(\.isReady).count, magnetFiles: files)
    }

    @Test func `only matching processing magnets justify a processing status`() async throws {
        let client = AvailabilityClient(snapshots: [snapshot([pending("Dune.2021.mkv"), pending("Other.2021")])])
        let resolver = CatalogSourceResolver(client: client)
        do { try await resolver.refresh(title: movie, episode: nil); Issue.record("Expected processing") }
        catch CatalogSourceResolver.Failure.processing {}
        #expect(resolver.availability == .processing)
        #expect(resolver.processingMagnets.map(\.filename) == ["Dune.2021.mkv"])
        #expect(resolver.sources.isEmpty)
        #expect(await client.resolveCount == 0)
    }

    @Test func `unrelated pending titles and wrong-year remakes do not hide a missing title`() async throws {
        let resolver = CatalogSourceResolver(client: AvailabilityClient(snapshots: [snapshot([
            pending("Dune.1984"),
            pending("Other.2021"),
        ])]))
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.refresh(
            title: movie,
            episode: nil,
        ) }
        #expect(resolver.availability == .missing)
        #expect(resolver.processingMagnets.isEmpty)
    }

    @Test func `processing to ready refresh resolves only the exact matching movie`() async throws {
        let client = AvailabilityClient(snapshots: [
            snapshot([pending("Dune.2021")]),
            snapshot([], files: [file("Dune.1984.2160p.mkv"), file("Dune.2021.1080p.mkv")]),
        ])
        let resolver = CatalogSourceResolver(client: client)
        await #expect(throws: CatalogSourceResolver.Failure.self) { try await resolver.refresh(
            title: movie,
            episode: nil,
        ) }
        try await resolver.refresh(title: movie, episode: nil)
        #expect(resolver.availability == .ready)
        let result = try await resolver.resolveNext()
        #expect(result.source.filename == "Dune.2021.1080p.mkv")
        #expect(await client.resolveCount == 1)
        #expect(await client.verifyCount == 1)
    }

    @Test func `season packs may be processing but ready episodes still require exact season and episode`(
    ) async throws {
        let show = TMDBTitle.reference(id: 2, kind: .tv, title: "Series", year: 2022)
        let episode = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":20,"name":"Two","season_number":1,"episode_number":2}"#.utf8),
        )
        #expect(AllDebridTitleMatcher.matchesProcessingMagnet(
            title: show,
            episode: episode,
            magnet: pending("Series.2022.S01.1080p"),
        ))
        #expect(!AllDebridTitleMatcher.matchesProcessingMagnet(
            title: show,
            episode: episode,
            magnet: pending("Series.2022.S02.1080p"),
        ))
        #expect(!AllDebridTitleMatcher.matchesProcessingMagnet(
            title: show,
            episode: episode,
            magnet: pending("Series.S01E01.mkv"),
        ))
        let resolver = CatalogSourceResolver(client: AvailabilityClient(snapshots: [snapshot(
            [],
            files: [file("Series.S01E01.mkv"), file("Series.S01E02.mkv"), file("Series.S02E02.mkv")],
        )]))
        try await resolver.refresh(title: show, episode: episode)
        #expect(resolver.sources.map(\.filename) == ["Series.S01E02.mkv"])
    }

    @Test func `a source outside the current matched snapshot cannot be selected`() async throws {
        let client = AvailabilityClient(snapshots: [snapshot([], files: [file("Dune.2021.mkv")])])
        let resolver = CatalogSourceResolver(client: client)
        try await resolver.refresh(title: movie, episode: nil)
        await #expect(throws: CatalogSourceResolver.Failure.self) {
            try await resolver.resolveSelected(.magnet(file("Other.2021.mkv")))
        }
        #expect(await client.resolveCount == 0)
    }

    @Test func `cancelled refresh cannot publish playable sources or resolve a URL`() async throws {
        let client = AvailabilityClient(snapshots: [snapshot([], files: [file("Dune.2021.mkv")])], waits: true)
        let resolver = CatalogSourceResolver(client: client)
        let task = Task { try await resolver.refresh(title: movie, episode: nil) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(resolver.sources.isEmpty)
        #expect(await client.resolveCount == 0)
    }

    @Test func `polling uses bounded processing and missing-library delays and hero uses seventy percent of its viewport`() {
        #expect(CatalogAvailabilityPolling.delay(processing: true, attempt: 0) == .seconds(10))
        #expect(CatalogAvailabilityPolling.delay(processing: true, attempt: 100) == .seconds(30))
        #expect(CatalogAvailabilityPolling.delay(processing: false, attempt: 0) == .seconds(30))
        #expect(CatalogAvailabilityPolling.delay(processing: false, attempt: 100) == .seconds(60))
        for available in [320.0, 568, 667, 740, 844, 874, 932] {
            #expect(HomeHeroSizing.iPhoneHeight(availableHeight: available) == available * 0.7)
        }
    }
}

private actor AvailabilityClient: CatalogPlaybackClient {
    let snapshots: [AllDebridLibrarySnapshot]
    let waits: Bool
    private var index = 0
    private(set) var resolveCount = 0
    private(set) var verifyCount = 0
    init(snapshots: [AllDebridLibrarySnapshot], waits: Bool = false) {
        self.snapshots = snapshots; self.waits = waits
    }

    func verifyConnection() async throws -> String? {
        verifyCount += 1; return "fixture"
    }

    func librarySnapshot() async throws -> AllDebridLibrarySnapshot {
        if waits {
            try await Task.sleep(for: .seconds(60))
        }
        let value = snapshots[min(index, snapshots.count - 1)]; index += 1; return value
    }

    func resolvePlaybackURL(_: String, filename _: String) async throws -> AllDebridPlaybackResolution {
        resolveCount += 1
        return AllDebridPlaybackResolution(
            url: URL(string: "https://media.test/video.mkv")!,
            statusCode: 200,
            contentType: "video/x-matroska",
            followedRedirect: false,
        )
    }
}
