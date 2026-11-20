@testable import Strimr
import Testing

struct ResumeVerificationTests {
    @Test func `a rendered landing confirms fractional resume without exact target callback equality`() {
        var state = ResumeVerification(target: 1824.75)
        let accepted = state.observe(actual: nil, display: 0, ready: false, paused: true, landed: 1825.1)
        #expect(accepted)
    }

    @Test func `a missing callback can be confirmed by actual native clock progress`() {
        var state = ResumeVerification(target: 600.125)
        let first = state.observe(actual: 600.125, display: 600.125, ready: true, paused: false, landed: nil)
        let second = state.observe(actual: 600.375, display: 600.375, ready: true, paused: false, landed: nil)
        #expect(!first)
        #expect(second)
    }

    @Test func `a paused seek can confirm after two ready native position samples`() {
        var state = ResumeVerification(target: 600.125)
        let first = state.observe(actual: 600.125, display: 600.125, ready: true, paused: true, landed: nil)
        let second = state.observe(actual: 600.125, display: 600.125, ready: true, paused: true, landed: nil)
        #expect(!first)
        #expect(second)
    }

    @Test func `optimistic engine time and temporary zero never prove success`() {
        var state = ResumeVerification(target: 600.125)
        for _ in 0 ..< 3 {
            let accepted = state.observe(actual: 0, display: 600.125, ready: true, paused: true, landed: nil)
            #expect(!accepted)
        }
        let unavailable = state.observe(actual: nil, display: 600.125, ready: true, paused: true, landed: nil)
        #expect(!unavailable)
    }

    @Test func `delayed readiness does not confirm a seek or consume retries`() {
        var state = ResumeVerification(target: 900)
        let attempted = state.requestSeek(ready: false, buffering: true, seeking: false, elapsed: 40, supported: nil)
        let accepted = state.observe(actual: 900, display: 900, ready: false, paused: false, landed: nil)
        #expect(!attempted)
        #expect(!accepted)
        #expect(state.attempts == 0)
        #expect(ResumeVerification.budget(remote: true, buffering: true) > 30)
    }

    @Test func `first ready seek can jump past buffering but retries wait for a settled engine`() {
        var state = ResumeVerification(target: 900)
        let initial = state.requestSeek(ready: true, buffering: true, seeking: false, elapsed: 60, supported: true)
        let tooSoon = state.requestSeek(ready: true, buffering: false, seeking: false, elapsed: 61, supported: true)
        let buffering = state.requestSeek(ready: true, buffering: true, seeking: false, elapsed: 100, supported: true)
        let inFlight = state.requestSeek(ready: true, buffering: false, seeking: true, elapsed: 100, supported: true)
        let retry = state.requestSeek(ready: true, buffering: false, seeking: false, elapsed: 100, supported: true)
        let exhausted = state.requestSeek(ready: true, buffering: false, seeking: false, elapsed: 200, supported: true)
        #expect(initial)
        #expect(!tooSoon && !buffering && !inFlight)
        #expect(retry)
        #expect(!exhausted)
        #expect(state.attempts == 2)
    }

    @Test func `unsupported seeking never initiates an automatic seek`() {
        var state = ResumeVerification(target: 900)
        let attempted = state.requestSeek(ready: true, buffering: false, seeking: false, elapsed: 100, supported: false)
        #expect(!attempted)
        #expect(state.attempts == 0)
    }

    @Test func `handoff correction requires settled corroborated wrong position`() {
        #expect(ResumeVerification.shouldCorrectHandoff(
            target: 900,
            native: 0,
            rendered: 0,
            settled: true,
            stableSeconds: 3,
        ))
        #expect(!ResumeVerification.shouldCorrectHandoff(
            target: 900,
            native: 0,
            rendered: 0,
            settled: false,
            stableSeconds: 30,
        ))
        #expect(!ResumeVerification.shouldCorrectHandoff(
            target: 900,
            native: 0,
            rendered: 0,
            settled: true,
            stableSeconds: 1,
        ))
        #expect(!ResumeVerification.shouldCorrectHandoff(
            target: 900,
            native: 0,
            rendered: 900,
            settled: true,
            stableSeconds: 30,
        ))
        #expect(!ResumeVerification.shouldCorrectHandoff(
            target: 900,
            native: 900,
            rendered: 900,
            settled: true,
            stableSeconds: 30,
        ))
    }

    @Test func `handoff checks do not confuse source PTS with display time`() {
        #expect(!ResumeVerification.shouldCorrectHandoff(
            target: 300,
            native: 900,
            rendered: 900,
            display: 300,
            settled: true,
            stableSeconds: 30,
        ))
        #expect(ResumeVerification.shouldCorrectHandoff(
            target: 900,
            native: 50,
            rendered: 50,
            display: 50,
            settled: true,
            stableSeconds: 3,
        ))
    }

    @Test func `late confirmation retains an explicit pause request`() {
        var state = ResumeVerification(target: 900)
        state.requestedPause = true
        let confirmed = state.observe(actual: nil, display: 0, ready: false, paused: true, landed: 900)
        #expect(confirmed)
        #expect(state.requestedPause == true)
    }

    @Test func `a positive fractional checkpoint never confirms a temporary zero`() {
        var state = ResumeVerification(target: 0.5)
        let accepted = state.observe(actual: 0, display: 0, ready: true, paused: true, landed: 0)
        #expect(!accepted)
        #expect(!state.near(0))
    }
}
