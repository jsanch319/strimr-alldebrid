import Foundation
@testable import Strimr
import Testing

struct SharePlaySessionLifecycleTests {
    @Test func `duplicate delivery while media access awaits cannot accept or leave the same session`() {
        let session = UUID(), other = UUID()
        #expect(SharePlaySessionLifecycle.shouldAccept(incoming: session, active: nil, accepting: nil))
        #expect(!SharePlaySessionLifecycle.shouldAccept(incoming: session, active: nil, accepting: session))
        #expect(!SharePlaySessionLifecycle.shouldAccept(incoming: session, active: session, accepting: nil))
        #expect(!SharePlaySessionLifecycle.mayLeaveRejected(incoming: session, active: session))
        #expect(SharePlaySessionLifecycle.mayLeaveRejected(incoming: other, active: session))
    }

    @Test func `stale source sheet dismissal cannot leave a new session`() {
        let old = UUID(), next = UUID()
        #expect(!SharePlaySessionLifecycle.ownsDismissal(expected: old, presented: next, active: next))
        #expect(!SharePlaySessionLifecycle.ownsDismissal(expected: old, presented: nil, active: next))
        #expect(!SharePlaySessionLifecycle.ownsDismissal(expected: nil, presented: next, active: next))
        #expect(SharePlaySessionLifecycle.ownsDismissal(expected: next, presented: next, active: next))
        #expect(SharePlaySessionLifecycle.ownsDismissal(expected: next, presented: nil, active: next))
    }
}
