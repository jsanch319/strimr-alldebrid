import AetherEngine
import Foundation
@testable import Strimr
import Testing

struct AllDebridAPIClientTests {
    @Test func `PIN authorization uses documented endpoints and verifies with bearer auth`() async throws {
        let stub = HTTPStub { request in
            switch request.url?.path {
            case "/v4.1/pin/get":
                .json(
                    #"{"status":"success","data":{"pin":"ABCD","check":"check-token","expires_in":600,"user_url":"https://alldebrid.com/pin/?pin=ABCD"}}"#,
                )
            case "/v4/pin/check":
                .json(#"{"status":"success","data":{"activated":true,"expires_in":570,"apikey":"user-api-key"}}"#)
            case "/v4/user":
                .json(#"{"status":"success","data":{"user":{"username":"user"}}}"#)
            default:
                .status(404)
            }
        }
        let client = AllDebridAPIClient(session: stub.session)

        let pin = try await client.requestPIN()
        let authorization = try await client.checkPIN(pin: pin.pin, check: pin.check)
        let apiKey = try #require(authorization.apiKey)
        let authenticatedClient = try AllDebridAPIClient(
            apiKey: apiKey,
            session: stub.session,
        )
        let username = try await authenticatedClient.verifyConnection()

        #expect(pin.pin == "ABCD")
        #expect(authorization.activated)
        #expect(username == "user")
        #expect(stub.requests.map(\.url?.path) == ["/v4.1/pin/get", "/v4/pin/check", "/v4/user"])
        #expect(stub.requests[0].httpMethod == "GET")
        #expect(stub.requests[1].httpMethod == "POST")
        #expect(
            try String(data: #require(stub.requests[1].httpBody), encoding: .utf8) == "pin=ABCD&check=check-token",
        )
        #expect(stub.requests[2].httpMethod == "GET")
        #expect(stub.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer user-api-key")
        #expect(stub.requests.allSatisfy { $0.url?.query == nil })
    }

    @Test func `verification rejects an invalid account response`() async throws {
        let stub = HTTPStub { _ in
            .json(#"{"status":"error","error":{"code":"AUTH_BAD_APIKEY","message":"Invalid API key"}}"#)
        }
        let client = try AllDebridAPIClient(apiKey: "invalid", session: stub.session)

        await #expect(throws: AllDebridAPIClient.APIError.serviceError("Invalid API key")) {
            try await client.verifyConnection()
        }
    }

    @Test func `ready magnet parsing accepts numeric and string IDs and excludes unfinished magnets`() async throws {
        let stub = HTTPStub { request in
            #expect(request.url?.path == "/v4.1/magnet/status")
            #expect(request.httpMethod == "POST")
            #expect(request.url?.query == nil)
            #expect(
                String(data: request.httpBody ?? Data(), encoding: .utf8)?
                    .contains("status=ready") == true,
            )
            return try .fixture("alldebrid-magnet-status")
        }
        let client = try AllDebridAPIClient(apiKey: "private-key", session: stub.session)

        let magnets = try await client.readyMagnets()

        #expect(magnets.map(\.id) == ["101", "102"])
        #expect(magnets.map(\.isReady) == [true, true])
        #expect(magnets[0].filename == "Movie.2024.2160p.WEB-DL.mkv")
        #expect(magnets[0].size == 12_000_000_000)
        #expect(magnets[1].statusCode == 4)
        #expect(stub.requests.first?.url?.query == nil)
    }

    @Test func `magnet file trees flatten recursively and preserve nested paths and direct links`() async throws {
        let stub = HTTPStub { request in
            #expect(request.url?.path == "/v4/magnet/files")
            #expect(request.httpMethod == "POST")
            #expect(request.url?.query == nil)
            return try .fixture("alldebrid-magnet-files")
        }
        let client = try AllDebridAPIClient(apiKey: "private-key", session: stub.session)

        let files = try await client.magnetFiles(for: ["101", "102"])

        #expect(files.count == 7)
        let movie = try #require(files.first { $0.filename == "Movie.2024.2160p.WEB-DL.mkv" })
        #expect(movie.magnetID == "101")
        #expect(movie.fullPath == "Movies/Movie (2024)/Movie.2024.2160p.WEB-DL.mkv")
        #expect(movie.link == "https://alldebrid.com/direct/movie-2160p")
        #expect(movie.isVideo)
        let subtitles = files.filter(\.isSubtitle)
        #expect(subtitles.count == 4)
        #expect(subtitles.map(\.fullPath) == [
            "Movies/Movie (2024)/Movie.2024.en.srt",
            "Movies/Movie (2024)/Movie.2024.ass",
            "Movies/Movie (2024)/Movie.2024.ssa",
            "Movies/Movie (2024)/Movie.2024.vtt",
        ])
        #expect(files.contains { $0.filename == "episode01.mp4" && $0.fullPath == "Series/Season 1/episode01.mp4" })
        #expect(stub.requests.count == 1)
        let requestBody = try #require(stub.requests[0].httpBody)
        let body = try #require(String(data: requestBody, encoding: .utf8))
        let bodyItems = URLComponents(string: "https://example.com/?\(body)")?.queryItems ?? []
        #expect(bodyItems.filter { $0.name == "id[]" }.compactMap(\.value) == ["101", "102"])
        #expect(bodyItems.first { $0.name == "apikey" }?.value == "private-key")
    }

    @Test func `empty magnet response returns no ready magnets or files`() async throws {
        let stub = HTTPStub { request in
            #expect(request.url?.path == "/v4.1/magnet/status")
            return try .fixture("alldebrid-magnet-empty")
        }
        let client = try AllDebridAPIClient(apiKey: "private-key", session: stub.session)

        let magnets = try await client.readyMagnets()
        let files = try await client.magnetFiles(for: magnets.map(\.id))

        #expect(magnets.isEmpty)
        #expect(files.isEmpty)
        #expect(stub.requests.count == 1)
    }

    @Test func `malformed magnet file entries are ignored`() async throws {
        let stub = HTTPStub { _ in try .fixture("alldebrid-magnet-malformed-files") }
        let client = try AllDebridAPIClient(apiKey: "private-key", session: stub.session)

        let files = try await client.magnetFiles(for: ["103"])

        #expect(files.count == 1)
        #expect(files[0].filename == "valid.mkv")
        #expect(files[0].fullPath == "Folder/valid.mkv")
    }

    @Test func `magnet selection filters non-video files and chooses the best version under the size limit`() {
        let files = [
            magnetFile("film-720p.mkv", size: 2_000_000_000),
            magnetFile("film-1080p.mkv", size: 8_000_000_000),
            magnetFile("film.1080p.mkv", size: 10_000_000_000),
            magnetFile("film-2160p.mkv", size: 20 * 1024 * 1024 * 1024 + 1),
            magnetFile("cover.jpg", size: 1000),
            magnetFile("episode01.mp4", size: 1_000_000_000, path: "Season 1/episode01.mp4"),
            magnetFile("other-1080p.mkv", size: 8_000_000_000, magnetID: "102"),
            magnetFile("other-2160p.mkv", size: 20 * 1024 * 1024 * 1024, magnetID: "102"),
        ]

        let selected = AllDebridLibraryView.selectBestVideos(files)

        #expect(Set(selected.map(\.filename)) == ["film.1080p.mkv", "episode01.mp4", "other-2160p.mkv"])
    }

    @Test func `manual magnet sources include oversized video files and sort by quality`() {
        let files = [
            magnetFile("film-1080p-h264.mkv", size: 15_000_000_000),
            magnetFile("film-2160p-hevc-dv.mkv", size: 25_000_000_000),
            magnetFile("film-2160p-h264.mkv", size: 18_000_000_000),
            magnetFile("cover.jpg", size: 1000),
            magnetFile("other-2160p.mkv", size: 30_000_000_000, magnetID: "102"),
        ]

        let sources = AllDebridLibraryView.sources(for: "101", in: files)

        #expect(sources.map(\.filename) == [
            "film-2160p-hevc-dv.mkv",
            "film-2160p-h264.mkv",
            "film-1080p-h264.mkv",
        ])
        #expect(AllDebridLibraryView.sourceDetails(sources[0]).contains("HEVC / H.265"))
        #expect(AllDebridLibraryView.sourceDetails(sources[0]).contains("Dolby Vision"))
    }

    @Test func `magnet movie titles omit release and encoding details`() {
        #expect(
            AllDebridLibraryView.cleanTitle("Movie.Name.2024.2160p.WEB-DL.DV.x265-GROUP.mkv") == "Movie Name 2024",
        )
    }

    @Test func `subtitle extension detection accepts supported extensions only`() {
        #expect(["srt", "ass", "ssa", "vtt"].allSatisfy {
            AllDebridSubtitleMatcher.isSubtitleFile("subtitles.\($0)")
        })
        #expect(AllDebridSubtitleMatcher.isSubtitleFile("subtitles.SRT"))
        #expect(!AllDebridSubtitleMatcher.isSubtitleFile("subtitles.idx"))
        #expect(!AllDebridSubtitleMatcher.isSubtitleFile("subtitles"))
    }

    @Test func `subtitle matching selects files for the exact video and rejects other episodes`() {
        let video = magnetFile("Show.S01E02.1080p.mkv", size: 1000, path: "Season 1/Show.S01E02.1080p.mkv")
        let files = [
            video,
            magnetFile("Show.S01E02.en.srt", size: 1, path: "Season 1/Subs/Show.S01E02.en.srt"),
            magnetFile("Show.S01E01.en.srt", size: 1, path: "Season 1/Show.S01E01.en.srt"),
            magnetFile("Another.Show.S01E02.en.srt", size: 1, path: "Season 1/Another.Show.S01E02.en.srt"),
        ]

        #expect(AllDebridSubtitleMatcher.subtitles(for: video, in: files).map(\.filename) == ["Show.S01E02.en.srt"])
    }

    @Test func `subtitle matcher prefers same folder among equally matching filenames`() {
        let video = magnetFile("Film.2024.mkv", size: 1000, path: "Movies/Film.2024.mkv")
        let elsewhere = magnetFile("Film.2024.en.srt", size: 1, path: "Subtitles/Film.2024.en.srt")
        let sameFolder = magnetFile("Film.2024.fr.srt", size: 1, path: "Movies/Film.2024.fr.srt")

        #expect(AllDebridSubtitleMatcher.subtitles(for: video, in: [video, elsewhere, sameFolder]) == [
            sameFolder,
            elsewhere,
        ])
    }

    @Test func `subtitle filename language tags are parsed`() {
        #expect(AllDebridSubtitleMatcher.language(in: "Film.en.srt") == "eng")
        #expect(AllDebridSubtitleMatcher.language(in: "Film.english.ass") == "eng")
        #expect(AllDebridSubtitleMatcher.language(in: "Film.spa.ssa") == "spa")
        #expect(AllDebridSubtitleMatcher.language(in: "Film.French.vtt") == "fre")
        #expect(AllDebridSubtitleMatcher.language(in: "Film.srt") == nil)
    }

    @Test func `manual source subtitle tracks use the selected source and same magnet`() {
        let first = magnetFile("Show.S01E01.mkv", size: 1000, path: "Season 1/Show.S01E01.mkv")
        let selected = magnetFile("Show.S01E02.mkv", size: 2000, path: "Season 1/Show.S01E02.mkv")
        let firstSubtitle = magnetFile("Show.S01E01.en.srt", size: 1, path: "Season 1/Show.S01E01.en.srt")
        let selectedSubtitle = magnetFile("Show.S01E02.spa.srt", size: 1, path: "Season 1/Show.S01E02.spa.srt")
        let otherMagnetSubtitle = magnetFile(
            "Show.S01E02.fr.srt",
            size: 1,
            path: "Season 1/Show.S01E02.fr.srt",
            magnetID: "102",
        )

        let tracks = AllDebridSubtitleMatcher.externalTracks(
            for: selected,
            in: [first, selected, firstSubtitle, selectedSubtitle, otherMagnetSubtitle],
        )

        #expect(tracks.map(\.url.absoluteString) == [selectedSubtitle.link])
        #expect(tracks.first?.language == "spa")
    }

    private func magnetFile(
        _ filename: String,
        size: Int64,
        path: String? = nil,
        magnetID: String = "101",
    ) -> AllDebridMagnetFile {
        AllDebridMagnetFile(
            id: "\(magnetID):\(filename)",
            magnetID: magnetID,
            filename: filename,
            fullPath: path ?? filename,
            size: size,
            link: "https://alldebrid.com/direct/\(filename)",
        )
    }
}
