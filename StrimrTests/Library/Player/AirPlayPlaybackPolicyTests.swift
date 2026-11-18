import Foundation
@testable import Strimr
import Testing

struct AirPlayPlaybackPolicyTests {
    @Test func `locking the phone does not pause a TV when background audio is disabled`() {
        #expect(!AirPlayPlaybackPolicy.shouldPauseForBackground(
            backgroundAudio: false, externalPlayback: true, airPlayRoute: false,
        ))
        #expect(!AirPlayPlaybackPolicy.shouldPauseForBackground(
            backgroundAudio: false, externalPlayback: false, airPlayRoute: true,
        ))
        #expect(AirPlayPlaybackPolicy.shouldPauseForBackground(
            backgroundAudio: false, externalPlayback: false, airPlayRoute: false,
        ))
        #expect(!AirPlayPlaybackPolicy.shouldPauseForBackground(
            backgroundAudio: true, externalPlayback: false, airPlayRoute: false,
        ))
    }

    @Test func `only a system authorized background native remote interruption resumes`() {
        #expect(AirPlayPlaybackPolicy.shouldResumeRemoteInterruption(
            wasPlaying: true, shouldResume: true, background: true,
            externalPlayback: true, nativeVideo: true, sameSession: true, coordinated: false,
        ))
        for blocked in 0 ..< 7 {
            #expect(!AirPlayPlaybackPolicy.shouldResumeRemoteInterruption(
                wasPlaying: blocked != 0, shouldResume: blocked != 1, background: blocked != 2,
                externalPlayback: blocked != 3, nativeVideo: blocked != 4,
                sameSession: blocked != 5, coordinated: blocked == 6,
            ))
        }
    }

    @Test func `HTTP denial is evidence of authorization failure not proof of expiration`() {
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
        ])
        #expect(AirPlayPlaybackPolicy.failure(error: wrapped, httpStatus: nil) == .network)
        #expect(AirPlayPlaybackPolicy.httpStatus(domain: "HTTP", code: 403) == 403)
        #expect(AirPlayPlaybackPolicy.httpStatus(domain: "CoreMediaErrorDomain", code: 403) == nil)
        #expect(AirPlayPlaybackPolicy.httpStatus(domain: nil, code: 403) == nil)
        #expect(AirPlayPlaybackPolicy.failure(domain: "", code: 0, httpStatus: 403) == .authorizationOrExpiredLink)
        #expect(AirPlayPlaybackPolicy.failure(domain: "", code: 0, httpStatus: 401) == .authorizationOrExpiredLink)
        #expect(AirPlayPlaybackPolicy.failure(domain: "", code: 0, httpStatus: 410) == .unavailable)
        #expect(AirPlayPlaybackPolicy.failure(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            httpStatus: nil,
        ) == .network)
        #expect(AirPlayPlaybackPolicy.failure(
            domain: "private-provider-error",
            code: 403,
            httpStatus: nil,
        ) == .playback)
    }

    @Test func `diagnostic source categories never include credentials hosts or signed URLs`() throws {
        for value in [
            "https://test-user:test-password@example.invalid/private/signed?token=test-secret",
            "https://192.168.1.42/private?key=test-secret",
        ] {
            let url = try #require(URL(string: value))
            #expect(AirPlayPlaybackPolicy.sourceCategory(url) == "remote-https")
        }
        let local = try #require(URL(string: "http://127.0.0.1:1234/private/master.m3u8"))
        #expect(AirPlayPlaybackPolicy.sourceCategory(local) == "loopback")
    }
}
