import SwiftUI

extension View {
    func posterRailNavigation(_ pagination: PosterRailPagination? = nil) -> some View {
        #if os(iOS)
            modifier(PosterRailNavigation(pagination: pagination))
        #else
            self
        #endif
    }
}

#if os(iOS)
    private struct RailGeometry: Equatable {
        let offset: CGFloat
        let width: CGFloat
        let maximum: CGFloat
        init(_ geometry: ScrollGeometry) {
            offset = max(0, geometry.contentOffset.x + geometry.contentInsets.leading)
            width = geometry.containerSize.width
            maximum = max(
                0,
                geometry.contentSize.width + geometry.contentInsets.leading + geometry.contentInsets.trailing - width,
            )
        }
    }

    private struct PosterRailNavigation: ViewModifier {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let pagination: PosterRailPagination?
        @State private var position = ScrollPosition(x: 0)
        @State private var geometry: RailGeometry?
        @State private var interacted = false

        func body(content: Content) -> some View {
            content
                .scrollPosition($position)
                .onScrollGeometryChange(for: RailGeometry.self) { RailGeometry($0) } action: { _, value in
                    geometry = value
                    prefetch()
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        interacted = true
                    }
                    if phase == .idle {
                        prefetch()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        arrow(
                            "chevron.left",
                            label: "Previous posters",
                            enabled: (geometry?.offset ?? 0) > 2,
                            forward: false,
                        )
                        Spacer(minLength: 8)
                        if pagination?.loading == true {
                            ProgressView().controlSize(.small).accessibilityLabel("Loading more titles")
                        }
                        arrow("chevron.right", label: "Next posters", enabled: canAdvance, forward: true)
                    }
                    .padding(4)
                }
                .accessibilityAction(named: "Next posters") { move(forward: true) }
                .accessibilityAction(named: "Previous posters") { move(forward: false) }
                .overlay(alignment: .bottomTrailing) {
                    if let error = pagination?.error {
                        Button { Task { await pagination?.loadMore() } } label: {
                            Label("Retry loading titles", systemImage: "arrow.clockwise")
                                .font(.caption).padding(8).background(.regularMaterial, in: Capsule())
                        }
                        .accessibilityHint(error)
                    }
                }
        }

        private var canAdvance: Bool {
            guard let geometry else { return false }
            return geometry.offset < geometry.maximum - 2 || pagination?.hasMore == true
        }

        private func arrow(_ symbol: String, label: String, enabled: Bool, forward: Bool) -> some View {
            Button { move(forward: forward) } label: {
                Image(systemName: symbol).font(.subheadline.weight(.semibold)).frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .videoOverlayGlass(in: Circle())
            .contentShape(Circle())
            .accessibilityIdentifier(forward ? "poster.rail.next" : "poster.rail.previous")
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.3)
            .accessibilityLabel(label)
        }

        private func move(forward: Bool) {
            guard let geometry else { return }
            interacted = true
            let target = max(0, geometry.offset + (forward ? 1 : -1) * max(44, geometry.width * 0.75))
            Task { @MainActor in
                if forward, target >= geometry.maximum, pagination?.hasMore == true {
                    await pagination?.loadMore()
                }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { position.scrollTo(x: target) }
            }
        }

        private func prefetch() {
            guard interacted, let geometry, geometry.offset + geometry.width * 0.6 >= geometry.maximum,
                  let pagination, pagination.hasMore, !pagination.loading, pagination.error == nil else { return }
            Task { await pagination.loadMore() }
        }
    }
#endif
