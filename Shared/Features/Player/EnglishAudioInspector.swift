import AVFoundation
import Foundation

@MainActor
protocol EnglishAudioInspecting {
    func containsEnglishAudio(at url: URL) async -> Bool
}

/// Metadata-only inspection. Never starts another player or guesses language from a release filename.
@MainActor
struct EnglishAudioInspector: EnglishAudioInspecting {
    func containsEnglishAudio(at url: URL) async -> Bool {
        let reference = AudioAssetReference(url: url)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            reference.asset.cancelLoading()
        }
        defer { timeout.cancel(); reference.asset.cancelLoading() }
        return await withTaskCancellationHandler {
            do {
                guard try await reference.asset.load(.isPlayable),
                      try await !(reference.asset.load(.hasProtectedContent)) else { return false }
                if let group = try await reference.asset.loadMediaSelectionGroup(for: .audible) {
                    if group.options
                        .contains(where: {
                            $0.isPlayable && EnglishAudioPreference
                                .isEnglish($0.extendedLanguageTag ?? $0.locale?.identifier)
                        })
                    {
                        return !Task.isCancelled
                    }
                }
                for track in try await reference.asset.loadTracks(withMediaType: .audio) {
                    let tag = try await track.load(.extendedLanguageTag)
                    let code = try await track.load(.languageCode)
                    if EnglishAudioPreference.isEnglish(tag ?? code) {
                        return !Task.isCancelled
                    }
                }
            } catch { return false }
            return false
        } onCancel: { reference.asset.cancelLoading() }
    }
}

/// AVAsset.cancelLoading is thread safe; the immutable reference permits cancellation from a task handler.
private final nonisolated class AudioAssetReference: @unchecked Sendable {
    let asset: AVURLAsset
    init(url: URL) {
        asset = AVURLAsset(url: url)
    }
}
