import Foundation
@testable import Strimr
import Testing

@MainActor
struct EnglishAudioPreferenceTests {
    private func track(
        _ id: Int,
        language: String?,
        title: String? = nil,
        selected: Bool = false,
        mainDefault: Bool = false,
        commentary: Bool = false,
        impaired: Bool = false,
    ) -> PlayerTrack {
        .init(
            id: id,
            ffIndex: id,
            providerStreamID: nil,
            type: .audio,
            title: title,
            language: language,
            codec: "aac",
            isDefault: mainDefault,
            isForced: false,
            isHearingImpaired: impaired,
            isCommentary: commentary,
            isExternal: false,
            isSelected: selected,
        )
    }

    @Test func `English is recognized only from actual language tags`() {
        for value in ["en", "eng", "EN", "en-US", "eng-GB", "en_AU", " ENG "] {
            #expect(EnglishAudioPreference.isEnglish(value))
        }
        for value in ["fra", "ben", "bengali", "English", "und", "", "fr-en"] {
            #expect(!EnglishAudioPreference.isEnglish(value))
        }
        #expect(EnglishAudioPreference.preferred(in: [track(1, language: "fra", title: "English 4K MULTI")]) == nil)
    }

    @Test func `English main wins over foreign default commentary and description`() {
        let tracks = [
            track(0, language: "fra", selected: true, mainDefault: true),
            track(1, language: "eng", title: "Director commentary", mainDefault: true),
            track(2, language: "en-US", title: "English Audio Description"),
            track(3, language: "eng", title: "Main English"),
        ]
        #expect(EnglishAudioPreference.preferred(in: tracks)?.id == 3)
        #expect(EnglishAudioPreference.preferred(in: [
            track(1, language: "en", commentary: true),
            track(2, language: "en"),
        ])?.id == 2)
        #expect(EnglishAudioPreference.preferred(in: [
            track(1, language: "en", impaired: true),
            track(2, language: "en"),
        ])?.id == 2)
    }

    @Test func `equivalent English choices retain default then active track deterministically`() {
        #expect(EnglishAudioPreference.preferred(in: [
            track(2, language: "en", selected: true),
            track(1, language: "eng", mainDefault: true),
        ])?.id == 1)
        #expect(EnglishAudioPreference.preferred(in: [
            track(2, language: "en", selected: true),
            track(1, language: "eng"),
        ])?.id == 2)
    }

    @Test func `unknown metadata is not evidence that English is absent`() {
        #expect(!EnglishAudioPreference.definitelyUnavailable(in: []))
        #expect(!EnglishAudioPreference.definitelyUnavailable(in: [track(1, language: nil)]))
        #expect(!EnglishAudioPreference.definitelyUnavailable(in: [track(1, language: "und-US")]))
        #expect(!EnglishAudioPreference.definitelyUnavailable(in: [track(1, language: "fra"), track(2, language: nil)]))
        #expect(EnglishAudioPreference.definitelyUnavailable(in: [
            track(1, language: "fra"),
            track(2, language: "deu"),
        ]))
    }

    @Test func `manual selections survive metadata refresh and load without English forcing`() {
        var session = EnglishAudioSession()
        let french = track(1, language: "fra"), english = track(2, language: "eng")
        #expect(session.selection(in: [french, english], enabled: true)?.id == 2)
        session.selectManually(french)
        #expect(session.selection(in: [french, english], enabled: true) == nil)
        session.beginLoad()
        #expect(session.selection(in: [french, english], enabled: true)?.id == 1)
        var disabled = EnglishAudioSession()
        #expect(disabled.selection(in: [french, english], enabled: false) == nil)
    }

    @Test func `manual language and role are retained when a replacement has different track IDs and codec`() {
        let chosen = track(2, language: "fr-CA", title: "French main")
        var session = EnglishAudioSession(manualTrack: chosen)
        let english = track(1, language: "eng", mainDefault: true)
        let french = PlayerTrack(
            id: 7,
            ffIndex: 7,
            providerStreamID: nil,
            type: .audio,
            title: "French main",
            language: "fr-FR",
            codec: "eac3",
            isDefault: false,
            isForced: false,
            isHearingImpaired: false,
            isCommentary: false,
            isExternal: false,
            isSelected: false,
        )
        #expect(session.selection(in: [english, french], enabled: true)?.id == 7)
        var next = EnglishAudioSession(manualTrack: track(2, language: "eng", title: "Commentary", commentary: true))
        #expect(next.selection(
            in: [track(9, language: "en-US", title: "Director commentary", commentary: true), english],
            enabled: true,
        )?.id == 9)
    }

    @Test func `late English metadata can improve an initial no-track result without repeated switching`() {
        var session = EnglishAudioSession()
        #expect(session.selection(in: [], enabled: true) == nil)
        #expect(session.selection(in: [track(1, language: "eng")], enabled: true)?.id == 1)
        #expect(session.selection(in: [track(1, language: "eng")], enabled: true) == nil)
    }

    @Test func `English preference defaults on migrates existing settings and respects opt out`() throws {
        #expect(PlaybackSettings().alwaysPreferEnglishAudio)
        #expect(try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8)).alwaysPreferEnglishAudio)
        var settings = PlaybackSettings(); settings.alwaysPreferEnglishAudio = false
        #expect(try !JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
            .alwaysPreferEnglishAudio)
    }

    private final class AudioBundleToken {}

    @Test func `native asset inspection reads real MP4 metadata rather than filename hints`() async throws {
        let bundle = Bundle(for: AudioBundleToken.self)
        let english = try #require(bundle.url(forResource: "metadata-french-default-english", withExtension: "mp4"))
        let french = try #require(bundle.url(forResource: "english-in-name-french-only", withExtension: "mp4"))
        #expect(await EnglishAudioInspector().containsEnglishAudio(at: english))
        #expect(await !EnglishAudioInspector().containsEnglishAudio(at: french))
    }

    @Test func `phone hero uses seventy percent except short landscape readability floor`() {
        for height in [320.0, 568, 667, 740, 844, 932] {
            #expect(HomeHeroSizing.iPhoneHeight(availableHeight: height) == height * 0.7)
        }
        #expect(HomeHeroSizing.iPhoneHeight(availableHeight: 260) == 200)
        #expect(HomeHeroSizing.iPhoneHeight(availableHeight: 160) == 160)
        for value in [-10.0, 0, .infinity, .nan] {
            #expect(HomeHeroSizing.iPhoneHeight(availableHeight: value) == 0)
        }
    }
}
