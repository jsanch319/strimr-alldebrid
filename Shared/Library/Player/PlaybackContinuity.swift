import Foundation

/// Protects the existing recorder and tracker clock while the engine replaces a native item.
/// This is a transient gate, not another persistence or playback system.
struct PlaybackContinuity {
    private(set) var position: Double = 0
    private(set) var restoring = false

    mutating func reset(to position: Double) {
        self.position = position.isFinite ? max(0, position) : 0
        restoring = self.position > 1
    }

    mutating func beginTransition() {
        restoring = position > 1
    }

    /// Explicit seeks, including Restart, supersede the handoff checkpoint.
    mutating func seek(to position: Double) {
        reset(to: position)
    }

    mutating func observe(_ candidate: Double) -> Bool {
        guard candidate.isFinite, candidate >= 0 else { return false }
        // Rebuilt HLS clocks can briefly publish a new item's zero-based timeline.
        // Do not release the gate until the engine has restored the carried playhead.
        guard !(position > 2 && candidate < 1),
              !restoring || candidate >= max(0, position - 2) else { return false }
        position = candidate
        restoring = false
        return true
    }
}
