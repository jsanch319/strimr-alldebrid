import SwiftUI

struct PlayerWrapper: View {
    let viewModel: PlayerViewModel
    var onPlaybackFailure: ((String) -> Void)?
    var englishAudioFallback: EnglishAudioFallback?

    var body: some View {
        PlayerView(
            viewModel: viewModel,
            onPlaybackFailure: onPlaybackFailure,
            englishAudioFallback: englishAudioFallback,
        )
        .transition(.opacity)
    }
}
