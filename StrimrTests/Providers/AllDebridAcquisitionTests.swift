import Foundation
@testable import Strimr
import Testing

struct AllDebridAcquisitionTests {
    @Test func `magnet upload uses documented POST body and validates per-item errors`() async throws {
        let magnet = "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&dn=Dune+2021"
        let stub = HTTPStub { request in
            #expect(request.url?.path == "/v4/magnet/upload")
            #expect(request.httpMethod == "POST")
            #expect(request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("%2B"))
            #expect(URLComponents(string: "https://test/?" + body)?.queryItems?.first { $0.name == "magnets[]" }?
                .value == magnet)
            return .json(#"{"status":"success","data":{"magnets":[{"id":42,"name":"Dune.2021","ready":true}]}}"#)
        }
        let client = try AllDebridAPIClient(apiKey: "fixture-key", session: stub.session)
        #expect(try await client.uploadMagnet(magnet) == "42")
        let rejected = HTTPStub { _ in
            .json(#"{"status":"success","data":{"magnets":[{"error":{"code":"MAGNET_INVALID_URI"}}]}}"#)
        }
        let rejectedClient = try AllDebridAPIClient(apiKey: "fixture-key", session: rejected.session)
        await #expect(throws: AllDebridAPIClient.APIError.self) { try await rejectedClient.uploadMagnet(magnet) }
    }

    @Test func `direct imports retain actual filename and do not unlock twice`() async throws {
        let stub = HTTPStub { request in
            if request.url?.path == "/v4/link/unlock" {
                return .json(
                    #"{"status":"success","data":{"filename":"Dune.2021.mkv","link":"https://media.test/movie.mkv"}}"#,
                )
            }
            #expect(request.httpMethod == "HEAD")
            return .init(statusCode: 200, headers: ["Content-Type": "video/x-matroska"])
        }
        let client = try AllDebridAPIClient(apiKey: "fixture-key", session: stub.session)
        guard case let .ready(link) = try await client.importDownloadLink("https://host.test/opaque")
        else { Issue.record("Expected ready"); return }
        #expect(link.filename == "Dune.2021.mkv")
        _ = try await client.resolvePlaybackURL(link.link, filename: link.filename)
        #expect(stub.requests.map(\.url?.path) == ["/v4/link/unlock", "/movie.mkv"])
    }

    @Test func `delayed download status preserves pending ready and failure distinctions`() async throws {
        for status in [1, 2, 3] {
            let stub = HTTPStub { request in
                #expect(request.url?.path == "/v4/link/delayed")
                #expect(request.httpMethod == "POST")
                #expect(request.url?.query == nil)
                return .json(
                    "{\"status\":\"success\",\"data\":{\"status\":\(status),\"link\":\"https://media.test/movie.mkv\"}}",
                )
            }
            let client = try AllDebridAPIClient(apiKey: "fixture-key", session: stub.session)
            if status == 3 {
                await #expect(throws: AllDebridAPIClient.APIError.self) { try await client.delayedDownload(
                    id: "7",
                    original: "https://host.test/file",
                    filename: "Dune.2021.mkv",
                ) }
            } else {
                let value = try await client.delayedDownload(
                    id: "7",
                    original: "https://host.test/file",
                    filename: "Dune.2021.mkv",
                )
                #expect((value != nil) == (status == 2))
            }
        }
    }

    @Test func `provider query carries exact catalog metadata without AllDebrid credentials`() async throws {
        let stub = HTTPStub { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.first { $0.name == "tmdb_id" }?.value == "1")
            #expect(query.first { $0.name == "year" }?.value == "2021")
            #expect(query.first { $0.name == "kind" }?.value == "movie")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return .json("[]")
        }
        let provider = try HTTPSAuthorizedSourceProvider(
            endpoint: #require(URL(string: "https://provider.test/search")),
            session: stub.session,
        )
        let results = try await provider.search(
            title: .reference(id: 1, kind: .movie, title: "Dune", year: 2021),
            episode: nil,
        )
        #expect(results.isEmpty)
    }
}
