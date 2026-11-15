import Foundation
@testable import Strimr
import Testing

struct DiscordWatchTogetherConfigurationTests {
    @Test func `configured Discord Activity link carries safe playback metadata`() throws {
        let server = ServerIdentity(provider: .plex, id: "server-1")
        let media = MediaItem.make(
            id: "movie-42",
            server: server,
            title: "A Film",
            type: .movie,
            viewOffset: 125,
        )

        let url = try #require(
            DiscordWatchTogetherConfiguration.activityLaunchURL(
                for: media,
                applicationID: "123456789012345678",
                activityURL: "https://watch.strimr.example/",
                position: 125,
                isPlaying: true,
                duration: 7200,
                selectedSourceIdentifier: "source-7",
            ),
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            },
        )

        #expect(url.host == "discord.com")
        #expect(url.path == "/activities/123456789012345678")
        #expect(query["media_id"] == "movie-42")
        #expect(query["title"] == "A Film")
        #expect(query["duration"] == "7200")
        #expect(query["position"] == "125")
        #expect(query["is_playing"] == "1")
        #expect(query["source_id"] == "source-7")
        #expect(Set(query.keys) == [
            "media_id",
            "title",
            "media_type",
            "duration",
            "position",
            "is_playing",
            "source_id",
        ])
    }

    @Test(arguments: [
        ("not-an-application-id", "https://watch.strimr.example"),
        ("123456789012345678", "http://watch.strimr.example"),
        ("123456789012345678", "https://user:password@watch.strimr.example"),
    ])
    func `invalid Discord configuration does not produce a launch URL`(
        applicationID: String,
        activityURL: String,
    ) {
        let server = ServerIdentity(provider: .plex, id: "server-1")
        let media = MediaItem.make(id: "movie-42", server: server, type: .movie)

        #expect(
            DiscordWatchTogetherConfiguration.activityLaunchURL(
                for: media,
                applicationID: applicationID,
                activityURL: activityURL,
            ) == nil,
        )
    }
}
