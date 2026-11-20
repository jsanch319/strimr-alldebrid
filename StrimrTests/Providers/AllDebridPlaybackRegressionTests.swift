import Foundation
@testable import Strimr
import Testing

struct AllDebridPlaybackRegressionTests {
    @Test func `a saved-link outage does not hide ready magnet files and reports incomplete refresh`() async throws {
        let stub = HTTPStub { request in
            switch request.url?.path {
            case "/v4/user/links": .status(503)
            case "/v4.1/magnet/status": .json(
                    #"{"status":"success","data":{"magnets":[{"id":1,"filename":"Movie.2024","statusCode":4}]}}"#,
                )
            case "/v4/magnet/files": .json(
                    #"{"status":"success","data":{"magnets":[{"id":1,"files":[{"n":"Movie.2024.mkv","l":"https://files.test/1","s":1024}]}]}}"#,
                )
            default: .status(404)
            }
        }
        let client = try AllDebridAPIClient(apiKey: "fixture-key", session: stub.session)
        let snapshot = try await client.librarySnapshot()
        #expect(snapshot.magnetFiles.count == 1)
        #expect(snapshot.warnings.count == 1)
        #expect(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" })
    }

    @Test func `expired authorization is not converted into an empty or partial library`() async throws {
        let stub = HTTPStub { _ in
            .json(#"{"status":"error","error":{"code":"AUTH_BAD_APIKEY","message":"Expired"}}"#)
        }
        let client = try AllDebridAPIClient(apiKey: "fixture-key", session: stub.session)
        await #expect(throws: AllDebridAPIClient.APIError.invalidAPIKey) { try await client.librarySnapshot() }
    }

    @Test func `single magnet and expanded file fields parse without silently returning an empty library`(
    ) async throws {
        let stub = HTTPStub { request in
            if request.url?.path == "/v4.1/magnet/status" {
                return .json(
                    #"{"status":"success","data":{"magnets":{"id":"1","filename":"Movie.2024","status":"4"}}}"#,
                )
            }
            return .json(
                #"{"status":"success","data":{"magnets":{"id":"1","files":[{"name":"Movie (2024)","children":[{"filename":"video.mkv","size":"1024","link":"https://files.test/1"}]}]}}}"#,
            )
        }
        let client = try AllDebridAPIClient(apiKey: "fixture-key", session: stub.session)
        #expect(try await client.magnets().first?.isReady == true)
        let files = try await client.magnetFiles(for: ["1"])
        #expect(files.first?.fullPath == "Movie (2024)/video.mkv")
    }

    @Test(arguments: [
        403,
        405,
        501,
    ]) func `HEAD rejection falls back to a bounded header-only GET`(_: Int) async throws {
        let stub = HTTPStub { request in
            if request.url?.path == "/v4/link/unlock" {
                return .json(#"{"status":"success","data":{"link":"https://files.test/video.mkv"}}"#)
            }
            if request.httpMethod == "HEAD" {
                return .status(405)
            }
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-0")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return .init(statusCode: 206, headers: ["Content-Type": "video/x-matroska"])
        }
        let client = try AllDebridAPIClient(apiKey: "fixture-key", session: stub.session)
        let result = try await client.resolvePlaybackURL("https://alldebrid.com/f/file", filename: "video.mkv")
        #expect(result.statusCode == 206)
        #expect(stub.requests.count == 3)
    }

    @Test func `large ready libraries are retrieved in bounded batches`() async throws {
        let stub = HTTPStub { request in
            switch request.url?.path {
            case "/v4/user/links": return .json(#"{"status":"success","data":{"links":[]}}"#)
            case "/v4.1/magnet/status":
                let magnets = (1 ... 101).map { ["id": $0, "filename": "Movie", "statusCode": 4] as [String: Any] }
                let data = try JSONSerialization.data(withJSONObject: [
                    "status": "success",
                    "data": ["magnets": magnets],
                ])
                return .json(String(decoding: data, as: UTF8.self))
            default:
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                let ids = (URLComponents(string: "https://stub.test/?" + body)?.queryItems ?? [])
                    .filter { $0.name == "id[]" }.compactMap(\.value)
                #expect(ids.count <= 100)
                let rows = ids.map { ["id": $0, "files": [[
                    "n": "Movie.mkv",
                    "l": "https://files.test/" + $0,
                ]]] as [String: Any] }
                let data = try JSONSerialization.data(withJSONObject: ["status": "success", "data": ["magnets": rows]])
                return .json(String(decoding: data, as: UTF8.self))
            }
        }
        let snapshot = try await AllDebridAPIClient(apiKey: "fixture-key", session: stub.session).librarySnapshot()
        #expect(snapshot.readyMagnetCount == 101)
        #expect(snapshot.magnetFiles.count == 101)
        #expect(stub.requests.filter { $0.url?.path == "/v4/magnet/files" }.count == 2)
    }
}
