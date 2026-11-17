import SwiftUI

extension View {
    func posterRailNavigation(_ pagination: PosterRailPagination? = nil, ids: [String] = []) -> some View {
        #if os(iOS)
            modifier(PosterRailNavigation(pagination: pagination, ids: ids))
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
        let ids: [String]
        @State private var position = ScrollPosition(edge: .leading)
        @State private var geometry: RailGeometry?
        @State private var interacted = false
        @State private var visibleIDs: Set<String> = []

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
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.98) { values in
                    visibleIDs = Set(values)
                    prefetch()
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        arrow(
                            "chevron.left",
                            label: "Previous posters",
                            enabled: interacted && (geometry?.offset ?? 0) > 2 && !firstVisible,
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

        private var diagnosticValue: String {
            #if DEBUG && targetEnvironment(simulator)
                if CatalogVisualFixtures.isEnabled {
                    return "offset=\(geometry?.offset ?? -1), maximum=\(geometry?.maximum ?? -1), width=\(geometry?.width ?? -1), more=\(pagination?.hasMore ?? false), first=\(ids.first ?? "none"), last=\(ids.last ?? "none"), visible=\(visibleIDs.sorted().joined(separator: ","))"
                }
            #endif
            return ""
        }

        private var firstVisible: Bool {
            ids.first.map { visibleIDs.contains($0) } ?? false
        }

        private var lastVisible: Bool {
            ids.last.map { visibleIDs.contains($0) } ?? false
        }

        private var canAdvance: Bool {
            guard let geometry else { return false }
            return (ids.isEmpty ? geometry.offset < geometry.maximum - 2 : !lastVisible) || pagination?.hasMore == true
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
            .accessibilityValue(diagnosticValue)
        }

        private func move(forward: Bool) {
            guard let geometry else { return }
            interacted = true
            let target = max(0, geometry.offset + (forward ? 1 : -1) * max(44, geometry.width * 0.75))
            Task { @MainActor in
                if forward, target >= geometry.maximum, pagination?.hasMore == true {
                    await pagination?.loadMore()
                }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    if target <= 0 {
                        position.scrollTo(edge: .leading)
                    } else {
                        position.scrollTo(x: target)
                    }
                }
            }
        }

        private func prefetch() {
            guard interacted, let geometry, lastVisible || geometry.offset + geometry.width * 0.6 >= geometry.maximum,
                  let pagination, pagination.hasMore, !pagination.loading, pagination.error == nil else { return }
            Task { await pagination.loadMore() }
        }
    }
#endif
