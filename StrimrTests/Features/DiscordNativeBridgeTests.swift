import Foundation
@testable import Strimr
import Testing

struct DiscordNativeBridgeTests {
    private let server = ServerIdentity(provider: .plex, id: "fixture")

    @Test func `native pairing carries exact episode and no private playback fields`() throws {
        let item = MediaItem.make(
            id: "tv:42:s2:e7",
            server: server,
            type: .episode,
            seasonNumber: 2,
            episodeNumber: 7,
            seriesTitle: "Series",
        )
        let metadata = try #require(DiscordNativeMedia(media: item, duration: 3600))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        #expect(json["mediaId"] as? String == "tv:42:s2:e7")
        #expect(json["season"] as? Int == 2)
        #expect(json["episode"] as? Int == 7)
        #expect(json["title"] as? String == "Series")
        #expect(Set(json.keys).isSubset(of: [
            "mediaId",
            "title",
            "mediaType",
            "season",
            "episode",
            "duration",
            "selectedSourceIdentifier",
        ]))
        #expect(json["selectedSourceIdentifier"] == nil)
    }

    @Test func `ambiguous episodes and URL identifiers cannot pair`() {
        #expect(DiscordNativeMedia(media: .make(id: "episode", server: server, type: .episode), duration: 3600) == nil)
        #expect(DiscordNativeMedia(
            media: .make(id: "https://private.test/video?token=secret", server: server),
            duration: 3600,
        ) == nil)
    }

    @Test func `clock ticks do not echo but intentional controls synchronize`() {
        let previous = DiscordPlaybackSample(position: 333.125, isPlaying: true)
        #expect(!DiscordSyncPolicy.shouldPublish(
            .init(position: 335.125, isPlaying: true),
            previous: previous,
            elapsed: 2,
            canControl: true,
            intentionalZeroSeek: false,
        ))
        #expect(DiscordSyncPolicy.shouldPublish(
            .init(position: 335.125, isPlaying: false),
            previous: previous,
            elapsed: 2,
            canControl: true,
            intentionalZeroSeek: false,
        ))
        #expect(DiscordSyncPolicy.shouldPublish(
            .init(position: 777.75, isPlaying: true),
            previous: previous,
            elapsed: 2,
            canControl: true,
            intentionalZeroSeek: false,
        ))
    }

    @Test func `temporary zero cannot replace resume and permissions remain authoritative`() {
        let previous = DiscordPlaybackSample(position: 333.125, isPlaying: true)
        #expect(!DiscordSyncPolicy.shouldPublish(
            .init(position: 0, isPlaying: false),
            previous: previous,
            elapsed: 2,
            canControl: true,
            intentionalZeroSeek: false,
        ))
        #expect(DiscordSyncPolicy.shouldPublish(
            .init(position: 0, isPlaying: true),
            previous: previous,
            elapsed: 2,
            canControl: true,
            intentionalZeroSeek: true,
        ))
        #expect(!DiscordSyncPolicy.shouldPublish(
            .init(position: 777, isPlaying: false),
            previous: previous,
            elapsed: 2,
            canControl: false,
            intentionalZeroSeek: true,
        ))
        #expect(!DiscordSyncPolicy.shouldPublish(
            .init(position: .nan, isPlaying: true),
            previous: previous,
            elapsed: 2,
            canControl: true,
            intentionalZeroSeek: true,
        ))
    }
}

struct DiscordNativeAcknowledgementTests {
    @Test func `a concurrent remote command is not mistaken for acknowledgement of a stale local sample`() {
        #expect(!DiscordSyncPolicy.acknowledgesLocalUpdate(accepted: false, revision: 8, sentRevision: 7))
        #expect(!DiscordSyncPolicy.acknowledgesLocalUpdate(accepted: nil, revision: 8, sentRevision: 7))
        #expect(DiscordSyncPolicy.acknowledgesLocalUpdate(accepted: true, revision: 8, sentRevision: 7))
        #expect(!DiscordSyncPolicy.acknowledgesLocalUpdate(accepted: true, revision: 9, sentRevision: 7))
    }

    @Test func `temporary zero samples must not replace the prior valid baseline`() {
        let previous = DiscordPlaybackSample(position: 333.125, isPlaying: true)
        #expect(DiscordSyncPolicy.isTemporaryZero(
            .init(position: 0, isPlaying: true),
            previous: previous,
            intentional: false,
        ))
        #expect(DiscordSyncPolicy.isTemporaryZero(
            .init(position: 0.2, isPlaying: false),
            previous: previous,
            intentional: false,
        ))
        #expect(!DiscordSyncPolicy.isTemporaryZero(
            .init(position: 0, isPlaying: false),
            previous: previous,
            intentional: true,
        ))
    }
}
