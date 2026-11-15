import Observation
import SwiftUI

/// A screen-local touch/scroll selection. It never uses tvOS remote focus or shares Settings artwork.
@MainActor
@Observable
final class CatalogBackdropSelection {
    struct Candidate {
        let media: MediaItem
        let bounds: CGRect
    }

    private(set) var selected: MediaItem?
    private var candidates: [UUID: Candidate] = [:]
    private var viewport = CGRect.zero

    var highlighted: MediaItem? {
        let target = CGPoint(x: viewport.minX + viewport.width * 0.3, y: viewport.minY + viewport.height * 0.42)
        return candidates.values.filter { candidate in
            let intersection = viewport.intersection(candidate.bounds)
            let area = candidate.bounds.width * candidate.bounds.height
            return area > 0 && !intersection.isNull && intersection.width * intersection.height / area >= 0.55
        }.min {
            let left = abs($0.bounds.midY - target.y) + abs($0.bounds.midX - target.x) * 0.45
            let right = abs($1.bounds.midY - target.y) + abs($1.bounds.midX - target.x) * 0.45
            return left == right ? $0.media.id < $1.media.id : left < right
        }?.media
    }

    func setViewport(_ bounds: CGRect) {
        if viewport != bounds {
            viewport = bounds
        }
    }

    func select(_ media: MediaItem) {
        selected = media
    }

    func clearTapPriority() {
        selected = nil
    }

    func update(_ media: MediaItem, bounds: CGRect, token: UUID) {
        guard media.guid.hasPrefix("tmdb://"), bounds.width > 0, bounds.height > 0 else { return }
        if let old = candidates[token], old.bounds == bounds, old.media == media {
            return
        }
        candidates[token] = Candidate(media: media, bounds: bounds)
    }

    func remove(token: UUID) {
        guard let removed = candidates.removeValue(forKey: token) else { return }
        if selected?.identity == removed.media.identity,
           !candidates.values.contains(where: { $0.media.identity == removed.media.identity })
        {
            selected = nil
        }
    }
}

extension EnvironmentValues {
    @Entry var catalogBackdropSelection: CatalogBackdropSelection? = nil
}

extension View {
    @ViewBuilder
    func catalogBackdrop(
        media: MediaItem?,
        selection: CatalogBackdropSelection? = nil,
        preferDefault: Bool = false,
        locked: Bool = false,
        details: Bool = false,
        enabled: Bool = true,
    ) -> some View {
        #if os(iOS)
            if enabled {
                modifier(CatalogBackdropSurface(
                    media: media,
                    externalSelection: selection,
                    preferDefault: preferDefault,
                    locked: locked,
                    details: details,
                ))
            } else {
                self
            }
        #else
            self
        #endif
    }

    func catalogBackdropCandidate(_ media: MediaItem?) -> some View {
        #if os(iOS)
            modifier(CatalogBackdropCandidate(media: media))
        #else
            self
        #endif
    }

    func catalogBackdropDisabled() -> some View {
        environment(\.catalogBackdropSelection, nil)
            .background(Color.background.ignoresSafeArea())
    }
}

#if os(iOS)
    private struct CatalogBackdropSurface: ViewModifier {
        let media: MediaItem?
        let externalSelection: CatalogBackdropSelection?
        let preferDefault: Bool
        let locked: Bool
        let details: Bool
        @State private var ownedSelection = CatalogBackdropSelection()
        private var selection: CatalogBackdropSelection {
            externalSelection ?? ownedSelection
        }

        private var displayedMedia: MediaItem? {
            if locked {
                return media
            }
            return selection.selected ?? (preferDefault ? media : selection.highlighted ?? media)
        }

        func body(content: Content) -> some View {
            content
                .environment(\.catalogBackdropSelection, locked ? nil : selection)
                .background { CatalogHomeBackdrop(media: displayedMedia, details: details) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { selection.setViewport($0) }
                .onScrollPhaseChange {
                    _, phase in if phase != .idle {
                        selection.clearTapPriority()
                    }
                }
                .onChange(of: media?.identity) { _, _ in selection.clearTapPriority() }
        }
    }

    private struct CatalogBackdropCandidate: ViewModifier {
        @Environment(\.catalogBackdropSelection) private var selection
        let media: MediaItem?
        @State private var token = UUID()
        @State private var bounds = CGRect.zero
        @State private var visible = false
        func body(content: Content) -> some View {
            if let selection, let media {
                content
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        bounds = $0
                        if visible {
                            selection.update(media, bounds: $0, token: token)
                        }
                    }
                    .onScrollVisibilityChange(threshold: 0.6) { visible in
                        self.visible = visible
                        if visible {
                            selection.update(media, bounds: bounds, token: token)
                        } else {
                            selection.remove(token: token)
                        }
                    }
                    .onChange(of: media) { _, _ in
                        if visible {
                            selection.update(media, bounds: bounds, token: token)
                        }
                    }
                    .onDisappear { selection.remove(token: token) }
            } else {
                content
            }
        }
    }
#endif
