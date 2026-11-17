import SwiftUI

struct PlayerWrapper: View {
    let viewModel: PlayerViewModel
    var onPlaybackFailure: ((String) -> Void)?

    var body: some View {
        PlayerView(viewModel: viewModel, onPlaybackFailure: onPlaybackFailure)
            .transition(.opacity)
    }
}
