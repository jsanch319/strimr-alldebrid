import Foundation
@testable import Strimr
import Testing

struct StremioTransportTests {
    @Test func `manifest validates mixed resource shapes and stream request identity`() async throws {
        let stub = HTTPStub { request in
            if request.url?.path.hasSuffix("manifest.json") == true {
                return .json(
                    #"{"id":"fixture","version":"1.0.0","name":"Torrentio","types":["movie","series"],"resources":["catalog",{"name":"stream","types":["movie","series"],"idPrefixes":["tt"]}]}"#,
                )
            }
            #expect(request.url?.path == "/private/stream/series/tt1234567:1:2.json")
            return .json(#"{"streams":[{"name":"4K","url":"https://cdn.test/movie.mkv"}]}"#)
        }
        let configuration = try StremioConfiguration(url: "https://addon.test/private/manifest.json", authorized: true)
        let client = StremioClient(session: stub.session)
        #expect(try await client.manifest(configuration).name == "Torrentio")
        #expect(try await client.streams(configuration, type: "series", id: "tt1234567:1:2").count == 1)
    }

    @Test func `transport retains more than one hundred standard streams and their file indices`() async throws {
        let rows = (0 ..< 130).map { [
            "infoHash": String(repeating: "a", count: 40),
            "fileIdx": $0,
            "behaviorHints": ["notWebReady": true],
        ] as [String: Any] }
        let payload = try #require(try String(
            data: JSONSerialization.data(withJSONObject: ["streams": rows]),
            encoding: .utf8,
        ))
        let stub = HTTPStub { _ in .json(payload) }
        let client = StremioClient(session: stub.session)
        let values = try await client.streams(
            .init(url: "https://addon.test/manifest.json", authorized: true),
            type: "series",
            id: "tt7631058:2:1",
        )
        #expect(values.count == 130)
        #expect(values.last?.fileIdx == 129)
        #expect(values.first?.behaviorHints?.notWebReady == true)
    }

    @Test func `catalog-only unconfigured and invalid manifests are rejected`() async throws {
        for raw in [
            #"{"id":"x","version":"1.0.0","name":"x","types":["movie"],"resources":["catalog"]}"#,
            #"{"id":"x","version":"1.0.0","name":"x","types":["movie"],"resources":["stream"],"behaviorHints":{"configurationRequired":true}}"#,
            "{}",
        ] {
            let stub = HTTPStub { _ in .json(raw) }
            let client = StremioClient(session: stub.session)
            await #expect(throws: StremioError.self) { try await client.manifest(.init(
                url: "https://addon.test/manifest.json",
                authorized: true,
            )) }
        }
    }

    @Test func `protected and external streams are filtered without extraction`() async throws {
        let stub = HTTPStub { _ in
            .json(
                #"{"streams":[{"url":"https://cdn.test/drm","drm":{"type":"widevine"}},{"externalUrl":"https://site.test/player"},{"ytId":"abc"},{"url":"https://cdn.test/video.mkv"}]}"#,
            )
        }
        let client = StremioClient(session: stub.session)
        let streams = try await client.streams(
            .init(url: "https://addon.test/manifest.json", authorized: true),
            type: "movie",
            id: "tt1160419",
        )
        #expect(streams.count == 4)
        #expect(streams.filter { $0.unsupportedReason == nil }.count == 1)
    }

    @Test func `transport failures never echo configured credentials`() async throws {
        let stub = HTTPStub { _ in throw URLError(
            .badURL,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://addon.test/fixtureOnly/manifest.json"],
        ) }
        let client = StremioClient(session: stub.session)
        do { _ = try await client.manifest(.init(
            url: "https://addon.test/fixtureOnly/manifest.json",
            authorized: true,
        )); Issue.record("Expected failure") } catch {
            #expect(!error.localizedDescription.contains("fixtureOnly")); #expect(error is StremioError)
        }
    }

    @Test func `rate limits have a safe distinct error`() async throws {
        let stub = HTTPStub { _ in .status(429) }
        let client = StremioClient(session: stub.session)
        do {
            _ = try await client.manifest(.init(url: "https://addon.test/manifest.json", authorized: true)); Issue
                .record("Expected rate limit")
        } catch StremioError.rateLimited {}
        await #expect(throws: StremioError.self) {
            try await client.manifest(.init(url: "https://addon.test/manifest.json", authorized: true))
        }
        #expect(stub.requests.count == 1)
    }

    @Test func `HTTPS playback validates headers without re-unlocking an AllDebrid URL`() async throws {
        let stub = HTTPStub { request in
            #expect(request.httpMethod == "HEAD")
            #expect(request.url?.host == "cdn.test")
            return .init(statusCode: 200, headers: ["Content-Type": "video/x-matroska"])
        }
        let client = StremioClient(session: stub.session)
        #expect(try await client.playbackURL(#require(URL(string: "https://cdn.test/file.mkv?token=fixtureOnly")))
            .host == "cdn.test")
        #expect(stub.requests.count == 1)
    }

    @Test func `web pages are rejected and HEAD-incompatible media gets a header-only range probe`() async throws {
        for html in [true, false] {
            let stub = HTTPStub { request in
                if request.httpMethod == "HEAD" {
                    return .status(405)
                }
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-0")
                return .init(statusCode: 200, headers: ["Content-Type": html ? "text/html" : "video/mp4"])
            }
            let client = StremioClient(session: stub.session)
            if html {
                await #expect(throws: StremioError.self) {
                    try await client.playbackURL(#require(URL(string: "https://cdn.test/file")))
                }
            } else {
                #expect(try await client.playbackURL(#require(URL(string: "https://cdn.test/file")))
                    .host == "cdn.test")
            }
        }
    }

    @Test func `metadata redirects cannot forward configuration to another origin or HTTP`() async throws {
        let origin = try #require(URL(string: "https://addon.test/fixtureOnly/manifest.json"))
        let delegate = StremioSecureRedirect(origin: origin)
        for target in ["https://other.test/path", "http://addon.test/path", "https://addon.test/path"] {
            let request = try URLRequest(url: #require(URL(string: target)))
            let result: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(
                    URLSession.shared,
                    task: URLSession.shared.dataTask(with: origin),
                    willPerformHTTPRedirection: HTTPURLResponse(
                        url: origin,
                        statusCode: 302,
                        httpVersion: nil,
                        headerFields: nil,
                    )!,
                    newRequest: request,
                ) { continuation.resume(returning: $0) }
            }
            #expect((result != nil) == (target == "https://addon.test/path"))
        }
    }
}
