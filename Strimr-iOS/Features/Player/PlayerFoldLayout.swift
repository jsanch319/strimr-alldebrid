import SwiftUI

/// Keeps the player in its full-screen layout on iOS, where the simulator SDK provides no public hinge geometry API.
struct PlayerFoldLayout<Video: View, VideoOverlay: View, Controls: View>: View {
    @Binding var mode: PlayerLayoutMode
    @Binding var hinge: PlayerHingeState
    var isPictureInPictureActive: Bool
    @ViewBuilder var video: Video
    @ViewBuilder var videoOverlay: VideoOverlay
    @ViewBuilder var controls: Controls

    var body: some View {
        video
    }
}
