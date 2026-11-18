@testable import Strimr
import Testing

struct PlaybackContinuityTests {
    @Test func `handoff zero never replaces an exact resume checkpoint`() {
        var clock = PlaybackContinuity()
        clock.reset(to: 1824.75)
        #expect(!clock.observe(0))
        #expect(!clock.observe(0.2))
        #expect(clock.position == 1824.75)
        #expect(clock.observe(1824.8))
        clock.beginTransition()
        #expect(!clock.observe(0))
        #expect(clock.observe(1825))
        #expect(clock.position == 1825)
        #expect(!clock.observe(0))
        #expect(clock.position == 1825)
    }

    @Test func `pause and repeated reconnects retain the same checkpoint`() {
        var clock = PlaybackContinuity()
        #expect(clock.observe(912.125))
        for _ in 0 ..< 3 {
            clock.beginTransition()
            #expect(!clock.observe(0))
            #expect(clock.position == 912.125)
        }
        #expect(clock.observe(912.125))
    }

    @Test func `intentional restart and remote scrubbing can return to zero`() {
        var clock = PlaybackContinuity()
        clock.reset(to: 900)
        clock.seek(to: 0)
        #expect(clock.observe(0))
        #expect(clock.position == 0)
        clock.seek(to: 100)
        #expect(!clock.observe(0))
        #expect(clock.observe(100))
    }

    @Test func `new episode never inherits a previous episodes checkpoint`() {
        var clock = PlaybackContinuity()
        clock.reset(to: 1200)
        clock.reset(to: 0)
        #expect(clock.observe(0))
        #expect(clock.observe(1))
        #expect(!clock.observe(.nan))
        #expect(!clock.observe(.infinity))
        #expect(!clock.observe(-1))
        #expect(clock.position == 1)
    }
}
