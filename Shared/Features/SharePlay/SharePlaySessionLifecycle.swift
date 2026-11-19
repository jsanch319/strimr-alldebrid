import Foundation

/// A dismissed old source sheet must not leave a newly accepted party.
enum SharePlaySessionLifecycle {
    static func shouldAccept(incoming: UUID, active: UUID?, accepting: UUID?) -> Bool {
        incoming != active && incoming != accepting
    }

    static func mayLeaveRejected(incoming: UUID, active: UUID?) -> Bool {
        incoming != active
    }

    static func ownsDismissal(expected: UUID?, presented: UUID?, active: UUID?) -> Bool {
        guard let expected else { return false }
        return (presented == nil || presented == expected) && (active == nil || active == expected)
    }
}
