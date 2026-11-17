import AVFoundation
@testable import Strimr
import Testing

#if os(iOS) || os(macOS)
    @MainActor
    struct PlayerAirPlayConfigurationTests {
        @Test func `AirPlay is allowed on every replacement without replacing the player or resetting playback preferences`() {
            for _ in 0 ..< 2 {
                let player = AVPlayer()
                player.allowsExternalPlayback = false
                player.volume = 0.4
                player.isMuted = true
                player.automaticallyWaitsToMinimizeStalling = false
                PlayerAirPlayConfiguration.apply(to: player)
                #expect(player.allowsExternalPlayback)
                #expect(player.audiovisualBackgroundPlaybackPolicy == .continuesIfPossible)
                #expect(player.volume == 0.4)
                #expect(player.isMuted)
                #expect(!player.automaticallyWaitsToMinimizeStalling)
                #expect(player.currentItem == nil)
            }
        }
    }
#endif
