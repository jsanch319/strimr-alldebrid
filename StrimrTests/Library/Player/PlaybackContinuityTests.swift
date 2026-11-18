@testable import Strimr
import Testing

struct PlaybackContinuityTests {
    @Test func `handoff zero never replaces an exact resume checkpoint`() {
        var clock = PlaybackContinuity()
        clock.reset(to: 1824.75)
        let accepted1 = clock.observe(0)
        #expect(!accepted1)
        let accepted2 = clock.observe(0.2)
        #expect(!accepted2)
        #expect(clock.position == 1824.75)
        let accepted3 = clock.observe(1824.8)
        #expect(accepted3)
        clock.beginTransition()
        let accepted4 = clock.observe(0)
        #expect(!accepted4)
        let accepted5 = clock.observe(1825)
        #expect(accepted5)
        #expect(clock.position == 1825)
        let accepted6 = clock.observe(0)
        #expect(!accepted6)
        let accepted7 = clock.observe(1)
        #expect(!accepted7)
        let accepted8 = clock.observe(2)
        #expect(!accepted8)
        #expect(clock.position == 1825)
    }

    @Test func `pause and repeated reconnects retain the same checkpoint`() {
        var clock = PlaybackContinuity()
        let accepted9 = clock.observe(912.125)
        #expect(accepted9)
        for _ in 0 ..< 3 {
            clock.beginTransition()
            let accepted10 = clock.observe(0)
            #expect(!accepted10)
            #expect(clock.position == 912.125)
        }
        let accepted11 = clock.observe(912.125)
        #expect(accepted11)
    }

    @Test func `intentional restart and remote scrubbing can return to zero`() {
        var clock = PlaybackContinuity()
        clock.reset(to: 900)
        clock.seek(to: 0)
        let accepted12 = clock.observe(0)
        #expect(accepted12)
        #expect(clock.position == 0)
        clock.seek(to: 100)
        let accepted13 = clock.observe(0)
        #expect(!accepted13)
        let accepted14 = clock.observe(100)
        #expect(accepted14)
    }

    @Test func `new episode never inherits a previous episodes checkpoint`() {
        var clock = PlaybackContinuity()
        clock.reset(to: 1200)
        clock.reset(to: 0)
        let accepted15 = clock.observe(0)
        #expect(accepted15)
        let accepted16 = clock.observe(1)
        #expect(accepted16)
        let accepted17 = clock.observe(.nan)
        #expect(!accepted17)
        let accepted18 = clock.observe(.infinity)
        #expect(!accepted18)
        let accepted19 = clock.observe(-1)
        #expect(!accepted19)
        #expect(clock.position == 1)
    }
}
