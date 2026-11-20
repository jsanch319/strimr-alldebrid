import Foundation
@testable import Strimr
import Testing

struct DiscordWatchTogetherConfigurationTests {
    @Test func `Discord is optional and absent or template configuration stays hidden`() {
        #expect(!DiscordWatchTogetherConfiguration.isConfigured(applicationID: nil, activityURL: nil))
        #expect(!DiscordWatchTogetherConfiguration.isConfigured(
            applicationID: "YOUR_DISCORD_APPLICATION_CLIENT_ID",
            activityURL: "https://your-strimr-activity-host.example",
        ))
        #expect(!DiscordWatchTogetherConfiguration.isConfigured(
            applicationID: "123456789012345678",
            activityURL: "https://your-strimr-activity-host.example",
        ))
        #expect(!DiscordWatchTogetherConfiguration.isConfigured(
            applicationID: "123456789012345678",
            activityURL: "http://watch.strimr.test",
        ))
        #expect(DiscordWatchTogetherConfiguration.isConfigured(
            applicationID: "123456789012345678",
            activityURL: "https://watch.strimr.test",
        ))
    }

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
                activityURL: "https://watch.strimr.test/",
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
        ("not-an-application-id", "https://watch.strimr.test"),
        ("123456789012345678", "http://watch.strimr.test"),
        ("123456789012345678", "https://user:password@watch.strimr.test"),
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
