import AVFoundation

#if os(iOS) || os(macOS)
    /// Apply to every engine-created AVPlayer, including replacements after route changes.
    /// Leave codec, bitrate, HDR, track selection, clock and rate decisions with the existing engine.
    enum PlayerAirPlayConfiguration {
        @MainActor static func apply(to player: AVPlayer) {
            player.allowsExternalPlayback = true
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
    }
#endif
