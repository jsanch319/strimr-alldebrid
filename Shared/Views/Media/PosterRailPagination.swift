import SwiftUI

extension View {
    func posterRailPagination(_ pagination: PosterRailPagination? = nil, ids: [String] = []) -> some View {
        #if os(iOS)
            modifier(PosterRailPaging(pagination: pagination, ids: ids))
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

    /// Observes the original native scroll view without imposing a position or adding navigation controls.
    private struct PosterRailPaging: ViewModifier {
        let pagination: PosterRailPagination?
        let ids: [String]
        @State private var geometry: RailGeometry?
        @State private var interacted = false
        @State private var visibleIDs: Set<String> = []
        @State private var prefetching = false

        func body(content: Content) -> some View {
            content
                .onScrollGeometryChange(for: RailGeometry.self) { RailGeometry($0) } action: { _, value in
                    geometry = value
                    prefetch()
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .animating {
                        interacted = true
                    }
                    if phase == .idle {
                        prefetch()
                    }
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.8) { values in
                    visibleIDs = Set(values)
                    prefetch()
                }
                .overlay(alignment: .trailing) {
                    if pagination?.loading == true {
                        ProgressView().controlSize(.small).padding(8)
                            .background(.regularMaterial, in: Circle())
                            .accessibilityLabel("Loading more titles")
                            .padding(4)
                    }
                }
                .accessibilityActions {
                    if let pagination, pagination.hasMore {
                        Button("Load more titles") { Task { await pagination.loadMore() } }
                            .disabled(pagination.loading)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let error = pagination?.error {
                        Button("Retry loading titles") { Task { await pagination?.loadMore() } }
                            .font(.caption).padding(8).background(.regularMaterial, in: Capsule())
                            .accessibilityHint(error)
                    }
                }
        }

        private func prefetch() {
            let lastVisible = ids.last.map { visibleIDs.contains($0) } ?? false
            guard interacted, !prefetching, let geometry,
                  lastVisible || geometry.offset + geometry.width * 0.6 >= geometry.maximum,
                  let pagination, pagination.hasMore, !pagination.loading, pagination.error == nil else { return }
            prefetching = true
            Task { @MainActor in
                await pagination.loadMore()
                prefetching = false
            }
        }
    }
#endif
