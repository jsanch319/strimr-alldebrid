import Foundation

/// Verifies the rendered/native clock, never the engine's optimistic scrub target alone.
struct ResumeVerification {
    let target: Double
    var requestedPause: Bool?
    private(set) var confirmations = 0
    private(set) var attempts = 0
    private var previousActual: Double?
    private var lastSeekElapsed: Double?

    init(target: Double) {
        self.target = target
        requestedPause = nil
    }

    mutating func observe(
        actual: Double?,
        display: Double,
        ready: Bool,
        paused: Bool,
        landed: Double?,
    ) -> Bool {
        if let landed, near(landed) {
            return true
        }
        guard ready, let actual, near(actual), near(display) else {
            confirmations = 0; previousActual = nil; return false
        }
        let advancing = previousActual.map { actual > $0 + 0.05 } ?? false
        previousActual = actual
        confirmations += 1
        return confirmations >= 2 && (paused || advancing)
    }

    func near(_ position: Double) -> Bool {
        position.isFinite && !(target > 0 && position == 0) &&
            position >= max(0, target - min(2, target * 0.1)) && position <= target + 6
    }

    mutating func requestSeek(
        ready: Bool,
        buffering: Bool,
        seeking: Bool,
        elapsed: Double,
        supported: Bool?,
    ) -> Bool {
        guard supported != false, ready, !seeking, attempts < 2,
              attempts == 0 || (!buffering && elapsed - (lastSeekElapsed ?? 0) >= 30) else { return false }
        attempts += 1
        lastSeekElapsed = elapsed
        return true
    }

    static func shouldCorrectHandoff(
        target: Double,
        native: Double?,
        rendered: Double,
        display: Double? = nil,
        settled: Bool,
        stableSeconds: Double,
    ) -> Bool {
        guard settled, stableSeconds >= 3, target > 2, let native,
              native.isFinite, rendered.isFinite, native >= 0, rendered >= 0,
              abs(native - rendered) <= 2 else { return false }
        // Source PTS and display time can have different origins (e.g. disc sources).
        // Zero corroboration is unambiguous; other positions also need axis agreement.
        let zero = native < 1 && rendered < 1
        let sameAxis = display.map { $0.isFinite && abs($0 - rendered) <= 2 } ?? false
        return (zero || sameAxis) && abs(rendered - target) > 8
    }

    static func budget(remote: Bool, buffering: Bool) -> Double {
        remote ? 180 : (buffering ? 120 : 60)
    }
}
