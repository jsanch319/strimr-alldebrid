import AVKit
import SwiftUI

/// Apple's route picker owns discovery, route selection and the active-route indicator.
/// It routes the existing engine; it never creates a second player or acquires a stream.
struct PlayerAirPlayButton: UIViewRepresentable {
    var onPresentationChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPresentationChanged: onPresentationChanged)
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.backgroundColor = .clear
        picker.delegate = context.coordinator
        picker.accessibilityIdentifier = "player.airplay"
        picker.accessibilityLabel = "AirPlay"
        picker.accessibilityHint = "Choose an Apple TV or compatible AirPlay device"
        return picker
    }

    func updateUIView(_: AVRoutePickerView, context: Context) {
        context.coordinator.onPresentationChanged = onPresentationChanged
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresentationChanged: (Bool) -> Void

        init(onPresentationChanged: @escaping (Bool) -> Void) {
            self.onPresentationChanged = onPresentationChanged
        }

        func routePickerViewWillBeginPresentingRoutes(_: AVRoutePickerView) {
            onPresentationChanged(true)
        }

        func routePickerViewDidEndPresentingRoutes(_: AVRoutePickerView) {
            onPresentationChanged(false)
        }
    }
}
