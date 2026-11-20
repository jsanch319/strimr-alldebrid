import Foundation
import Observation

/// Language comes only from track metadata; display names never establish a language.
enum EnglishAudioPreference {
    static func languageRoot(_ language: String?) -> String? {
        guard let language else { return nil }
        let root = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return root == "eng" ? "en" : root
    }

    static func isEnglish(_ language: String?) -> Bool {
        languageRoot(language) == "en"
    }

    static func preferred(in tracks: [PlayerTrack]) -> PlayerTrack? {
        tracks.filter { $0.type == .audio && isEnglish($0.language) }.sorted {
            let left = secondaryRank($0), right = secondaryRank($1)
            if left != right {
                return left < right
            }
            if $0.isDefault != $1.isDefault {
                return $0.isDefault
            }
            if $0.isSelected != $1.isSelected {
                return $0.isSelected
            }
            return $0.id < $1.id
        }.first
    }

    private static func secondaryRank(_ track: PlayerTrack) -> Int {
        let title = track.title?.lowercased() ?? ""
        if track.isCommentary || title.range(
            of: #"\b(commentary|commentaries|director.s comments)\b"#,
            options: .regularExpression,
        ) != nil {
            return 3
        }
        if title.range(
            of: #"\b(audio description|descriptive audio|described audio|visually impaired|described video|ad)\b"#,
            options: .regularExpression,
        ) != nil {
            return 2
        }
        return track.isHearingImpaired ? 1 : 0
    }

    static func definitelyUnavailable(in tracks: [PlayerTrack]) -> Bool {
        let audio = tracks.filter { $0.type == .audio }
        return !audio.isEmpty && preferred(in: audio) == nil && audio.allSatisfy {
            guard let value = $0.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            else { return false }
            let root = value.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            return !["", "und", "unknown", "unk", "mul", "zxx"].contains(root)
        }
    }
}

struct EnglishAudioSession {
    private(set) var manualTrack: PlayerTrack?
    private var appliedID: Int?
    var triedServerSwitch = false
    var triedSourceFallback = false

    mutating func selectManually(_ track: PlayerTrack) {
        manualTrack = track; appliedID = track.id
    }

    mutating func beginLoad() {
        appliedID = nil
    }

    init(manualTrack: PlayerTrack? = nil) {
        self.manualTrack = manualTrack
    }

    mutating func selection(in tracks: [PlayerTrack], enabled: Bool) -> PlayerTrack? {
        let target: PlayerTrack?
        if let manualTrack {
            let matches = tracks.filter {
                $0.language == manualTrack.language && $0.title == manualTrack.title && $0.codec == manualTrack.codec
            }
            let sameLanguage = tracks.filter {
                guard let expected = EnglishAudioPreference.languageRoot(manualTrack.language) else { return false }
                return EnglishAudioPreference.languageRoot($0.language) == expected
            }
            target = matches.first { $0.id == manualTrack.id } ?? matches.first
                ?? sameLanguage.first { $0.title == manualTrack.title }
                ?? sameLanguage
                .first {
                    $0.isCommentary == manualTrack.isCommentary && $0.isHearingImpaired == manualTrack
                        .isHearingImpaired
                }
                ?? sameLanguage.first
        } else {
            target = enabled ? EnglishAudioPreference.preferred(in: tracks) : nil
        }
        guard let target, target.id != appliedID else { return nil }
        appliedID = target.id
        return target
    }
}

@MainActor
@Observable
final class EnglishAudioPlaybackContext {
    var manualTrack: PlayerTrack?
}

@MainActor
struct EnglishAudioFallback {
    var context: EnglishAudioPlaybackContext?
    let find: @MainActor () async -> CatalogSourceResolver.Resolved?
    let activate: @MainActor (CatalogSourceResolver.Resolved, Double) -> Void
    var chooseSource: (@MainActor () -> Void)?
}
