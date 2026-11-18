import AVFoundation
import Foundation

/// Temporary verification samples from the engine-owned AVPlayer, without synchronous
/// currentTime XPC polling on every rendered-clock tick. Never creates a player or stores progress.
@MainActor
final class NativeResumeClock {
    private final class Observation {
        let player: AVPlayer
        let token: Any
        init(player: AVPlayer, token: Any) {
            self.player = player; self.token = token
        }

        deinit { player.removeTimeObserver(token) }
    }

    private var observation: Observation?
    private var generation = UUID()
    private var onSample: (@MainActor () -> Void)?
    private(set) var position: Double?

    func observe(_ player: AVPlayer?, onSample: @escaping @MainActor () -> Void) {
        if let player, observation?.player === player {
            return
        }
        reset()
        guard let player else { return }
        self.onSample = onSample
        let expected = generation
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main,
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, generation == expected, time.seconds.isFinite, time.seconds >= 0 else { return }
                position = time.seconds
                self.onSample?()
            }
        }
        observation = Observation(player: player, token: token)
    }

    func reset() {
        generation = UUID(); observation = nil; position = nil; onSample = nil
    }
}
