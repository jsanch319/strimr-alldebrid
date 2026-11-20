import AVFoundation
import Foundation

/// Remote HLS owns its AVFoundation selection; engine FFmpeg stream indexes cannot select these options.
@MainActor
final class NativeAudioSelection {
    let item: AVPlayerItem
    private let group: AVMediaSelectionGroup
    private let titles: [String]
    private init(item: AVPlayerItem, group: AVMediaSelectionGroup, titles: [String]) {
        self.item = item; self.group = group; self.titles = titles
    }

    static func prepare(item: AVPlayerItem) async -> NativeAudioSelection? {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
              !group.options.isEmpty else { return nil }
        var titles: [String] = []
        for option in group.options {
            var title = option.displayName
            for metadata in option.commonMetadata where metadata.identifier?.rawValue == "m3u8/NAME" {
                if let name = try? await metadata.load(.stringValue) {
                    title = name; break
                }
            }
            titles.append(title)
        }
        return NativeAudioSelection(item: item, group: group, titles: titles)
    }

    func select(id: Int) {
        let id = id - 900_000
        guard group.options.indices.contains(id), group.options[id].isPlayable else { return }
        item.select(group.options[id], in: group)
    }

    func tracks() -> [PlayerTrack] {
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().filter(\.element.isPlayable).map { index, option in
            PlayerTrack(
                id: 900_000 + index,
                ffIndex: nil,
                providerStreamID: nil,
                type: .audio,
                title: titles[index],
                language: option.extendedLanguageTag ?? option.locale?.identifier,
                codec: nil,
                isDefault: group.defaultOption.map { option.isEqual($0) } ?? false,
                isForced: false,
                isHearingImpaired: option.hasMediaCharacteristic(.describesVideoForAccessibility),
                isCommentary: option.hasMediaCharacteristic(.isAuxiliaryContent),
                isExternal: false,
                isSelected: selected.map { option.isEqual($0) } ?? false,
            )
        }
    }
}
