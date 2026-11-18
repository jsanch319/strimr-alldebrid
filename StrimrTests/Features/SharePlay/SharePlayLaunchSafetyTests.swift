import Foundation
@testable import Strimr
import Testing

struct SharePlayLaunchSafetyTests {
    @Test func `unknown or stripped signing evidence blocks launch`() {
        for signature in [nil, false, true] as [Bool?] {
            for profile in [nil, false, true] as [Bool?] {
                #expect(SharePlaySigningCheck.permitsLaunch(signature: signature, profile: profile) ==
                    (signature == true && profile == true))
            }
        }
    }

    @Test func `one invitation owns activation until session arrival`() {
        var guardState = SharePlayLaunchGuard()
        let first = UUID(), other = UUID(), now = Date()
        #expect(guardState.begin(first, now: now))
        #expect(!guardState.begin(first, now: now))
        #expect(!guardState.begin(other, now: now))
        guardState.finish(other, now: now) // stale sheet cannot release current request
        #expect(guardState.activeID == first)
        guardState.finish(first, now: now)
        #expect(!guardState.begin(other, now: now))
        #expect(guardState.begin(other, now: now.addingTimeInterval(2)))
        guardState.finish(other, cooldown: false, now: now.addingTimeInterval(2))
        #expect(guardState.activeID == nil)
    }

    @Test func `profile evidence is parsed without exposing private fields`() throws {
        let xml = try PropertyListSerialization.data(
            fromPropertyList: ["Entitlements": [SharePlaySigningCheck.entitlement: true], "TeamName": "private"],
            format: .xml, options: 0,
        )
        #expect(SharePlaySigningCheck.profileEntitlement(Data([1, 2, 3]) + xml + Data([0])) == true)
        #expect(SharePlaySigningCheck.profileEntitlement(Data("not a profile".utf8)) == nil)
        let missing = try PropertyListSerialization.data(
            fromPropertyList: ["Entitlements": [:]],
            format: .xml,
            options: 0,
        )
        #expect(SharePlaySigningCheck.profileEntitlement(missing) == false)
    }

    @Test func `installed executable signature distinguishes present missing and malformed evidence`() throws {
        let enabled = try executable(enabled: true)
        #expect(SharePlaySigningCheck.signedEntitlement(enabled) == true)
        #expect(try SharePlaySigningCheck.signedEntitlement(executable(enabled: false)) == false)
        #expect(try SharePlaySigningCheck.signedEntitlement(executable(enabled: nil)) == false)
        for length in [0, 4, 24, 32, 48, enabled.count - 1] {
            #expect(SharePlaySigningCheck.signedEntitlement(Data(enabled.prefix(length))) == nil)
        }
        var corrupt = enabled
        corrupt.replaceSubrange(44 ..< 48, with: [0xFF, 0xFF, 0xFF, 0x7F])
        #expect(SharePlaySigningCheck.signedEntitlement(corrupt) == nil)
        corrupt = enabled
        corrupt.replaceSubrange(60 ..< 64, with: [0, 0, 0, 7]) // DER-only/unknown slot
        #expect(SharePlaySigningCheck.signedEntitlement(corrupt) == nil)
        corrupt = enabled
        corrupt.replaceSubrange(64 ..< 68, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(SharePlaySigningCheck.signedEntitlement(corrupt) == nil)
    }

    private func executable(enabled: Bool?) throws -> Data {
        let values: [String: Any] = enabled.map { [SharePlaySigningCheck.entitlement: $0] } ?? [:]
        let xml = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        func word(_ value: UInt32, big: Bool = false) -> Data {
            let shifts = big ? [24, 16, 8, 0] : [0, 8, 16, 24]
            return Data(shifts.map { UInt8(truncatingIfNeeded: value >> $0) })
        }
        var data = word(0xFEED_FACF) + Data(repeating: 0, count: 12)
        data += word(1) + word(16) + Data(repeating: 0, count: 8)
        let size = UInt32(28 + xml.count)
        data += word(0x1D) + word(16) + word(48) + word(size)
        data += word(0xFADE_0CC0, big: true) + word(size, big: true) + word(1, big: true)
        data += word(5, big: true) + word(20, big: true)
        data += word(0xFADE_7171, big: true) + word(UInt32(xml.count + 8), big: true) + xml
        return data
    }

    @Test func `invalid initial clocks and empty titles cannot reach GroupActivities`() {
        func activity(_ title: String, time: Double) -> StrimrWatchActivity {
            StrimrWatchActivity(
                activityID: UUID(),
                provider: .plex,
                serverIdentifier: "server",
                ratingKey: "movie",
                mediaKind: .movie,
                title: title,
                initialPosition: time,
            )
        }
        #expect(activity("Movie", time: 0).hasValidSharePlayMetadata)
        #expect(!activity(" ", time: 1).hasValidSharePlayMetadata)
        #expect(!activity("Movie", time: .nan).hasValidSharePlayMetadata)
        #expect(!activity("Movie", time: .infinity).hasValidSharePlayMetadata)
        #expect(!activity("Movie", time: -1).hasValidSharePlayMetadata)
    }
}
