import Foundation

/// One owner across native invitation, activation and delayed session delivery.
struct SharePlayLaunchGuard {
    private(set) var activeID: UUID?
    private var nextAttempt = Date.distantPast

    mutating func begin(_ id: UUID, now: Date = .now) -> Bool {
        guard activeID == nil, now >= nextAttempt else { return false }
        activeID = id
        return true
    }

    mutating func finish(_ id: UUID, cooldown: Bool = true, now: Date = .now) {
        guard activeID == id else { return }
        activeID = nil
        nextAttempt = cooldown ? now.addingTimeInterval(2) : now
    }
}
