import SwiftUI

struct PlayerWrapper: View {
    let viewModel: PlayerViewModel
    var onPlaybackFailure: ((String) -> Void)?
    var englishAudioFallback: EnglishAudioFallback?
    var onRestartFromBeginning: (() -> Void)?

    var body: some View {
        PlayerView(
            viewModel: viewModel,
            onPlaybackFailure: onPlaybackFailure,
            englishAudioFallback: englishAudioFallback,
            onRestartFromBeginning: onRestartFromBeginning,
        )
        .transition(.opacity)
    }
}
