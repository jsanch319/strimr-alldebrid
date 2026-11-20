import AVFoundation

#if os(iOS) || os(macOS)
    /// Apply to every engine-created AVPlayer, including replacements after route changes.
    /// Leave codec, bitrate, HDR, track selection, clock and rate decisions with the existing engine.
    enum PlayerAirPlayConfiguration {
        /// Only native remote streams need this cushion. Never change the engine's local
        /// loopback producer, bitrate, HDR or track selection to compensate for Wi-Fi stalls.
        @MainActor static func applyRemoteBuffering(to player: AVPlayer, item: AVPlayerItem) {
            guard player.isExternalPlaybackActive else { return }
            player.automaticallyWaitsToMinimizeStalling = true
            item.preferredForwardBufferDuration = max(item.preferredForwardBufferDuration, 20)
        }

        @MainActor static func apply(to player: AVPlayer) {
            player.allowsExternalPlayback = true
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
    }
#endif
