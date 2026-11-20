import Foundation
@testable import Strimr
import Testing

@MainActor
struct EnglishAudioSourceTests {
    private let movie = TMDBTitle.reference(id: 1, kind: .movie, title: "Dune", year: 2021)
    private func resolver() -> CatalogSourceResolver {
        CatalogSourceResolver(client: AudioLibraryFixture())
    }

    @Test func `alternative requires verified audio and does not consume unconfirmed fallback files`() async throws {
        let resolver = resolver()
        try await resolver.refresh(title: movie, episode: nil)
        _ = try await resolver.resolveNext()
        let probe = AudioInspectorFixture(confirmed: false)
        #expect(try await resolver.englishAudioAlternative(inspector: probe) == nil)
        #expect(probe.calls.count == 3)
        let ordinaryFallback = try await resolver.resolveNext()
        #expect(ordinaryFallback.source.filename.contains("1080p"))
    }

    @Test func `verified alternative is only consumed when accepted for replacement`() async throws {
        let resolver = resolver()
        try await resolver.refresh(title: movie, episode: nil)
        _ = try await resolver.resolveNext()
        let candidate = try #require(try await resolver
            .englishAudioAlternative(inspector: AudioInspectorFixture(confirmed: true)))
        #expect(candidate.source.filename.contains("1080p"))
        #expect(resolver.acceptEnglishAudioAlternative(candidate))
        #expect(!resolver.acceptEnglishAudioAlternative(candidate))
        #expect(try await resolver.resolveNext().source.filename.contains("720p"))
    }

    @Test func `language inspection never unlocks a saved hoster link`() async throws {
        let library = AudioLibraryFixture(includesSaved: true)
        let resolver = CatalogSourceResolver(client: library)
        try await resolver.refresh(title: movie, episode: nil)
        _ = try await resolver.resolveNext()
        _ = try await resolver.englishAudioAlternative(inspector: AudioInspectorFixture(confirmed: false))
        #expect(await library.hosterUnlocks == 0)
    }

    @Test func `cancelled audio inspection never returns a replacement`() async throws {
        let resolver = resolver()
        try await resolver.refresh(title: movie, episode: nil)
        _ = try await resolver.resolveNext()
        let probe = AudioInspectorFixture(confirmed: true, waits: true)
        let task = Task { try await resolver.englishAudioAlternative(inspector: probe) }
        for _ in 0 ..< 100 {
            if !probe.calls.isEmpty {
                break
            }; await Task.yield()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@MainActor
private final class AudioInspectorFixture: EnglishAudioInspecting {
    let confirmed: Bool
    let waits: Bool
    var calls: [URL] = []
    init(confirmed: Bool, waits: Bool = false) {
        self.confirmed = confirmed; self.waits = waits
    }

    func containsEnglishAudio(at url: URL) async -> Bool {
        calls.append(url)
        if waits {
            try? await Task.sleep(for: .seconds(60))
        }
        return confirmed
    }
}

private actor AudioLibraryFixture: CatalogPlaybackClient {
    let includesSaved: Bool
    private(set) var hosterUnlocks = 0
    init(includesSaved: Bool = false) {
        self.includesSaved = includesSaved
    }

    func verifyConnection() -> String? {
        "fixture"
    }

    func librarySnapshot() -> AllDebridLibrarySnapshot {
        let files = ["2160p", "1080p", "720p", "480p", "360p"].map { quality in
            let name = "Dune.2021.\(quality).mkv"
            return AllDebridMagnetFile(
                id: name,
                magnetID: "m",
                filename: name,
                fullPath: name,
                size: 100,
                link: "https://files.test/\(quality)",
            )
        }
        return .init(
            savedLinks: includesSaved ? [.init(
                id: "saved",
                filename: "Dune.2021.1080p.mp4",
                link: "https://hoster.test/link",
            )] : [],
            magnets: [],
            readyMagnetCount: 1,
            magnetFiles: files,
        )
    }

    func resolvePlaybackURL(_ link: String, filename _: String) -> AllDebridPlaybackResolution {
        if link.contains("hoster.test") {
            hosterUnlocks += 1
        }
        return .init(url: URL(string: link)!, statusCode: 200, contentType: "video/x-matroska", followedRedirect: false)
    }
}
