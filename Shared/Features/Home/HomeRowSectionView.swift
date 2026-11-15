import SwiftUI

struct HomeRowSectionView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.mediaCardActions) private var mediaCardActions
    let row: HomeRow
    let showsLabels: Bool
    var canOpenWithoutServer = false
    let onViewAll: (Hub) -> Void
    let onSelectMedia: (MediaDisplayItem) -> Void

    var body: some View {
        MediaHubSection(
            title: row.title,
            subtitle: row.serverName,
            onViewAll: canOpenViewAll ? { onViewAll(row.hub) } : nil,
        ) {
            MediaCarousel(
                layout: row.style == .landscape ? .landscape : .portrait,
                items: row.items,
                showsLabels: showsLabels,
                onViewAll: carouselViewAllAction,
                onSelectMedia: select,
            )
            .environment(\.mediaCardOffersDetails, playsOnSelect)
            .environment(\.mediaCardIsInContinueWatching, row.kind == .continueWatching)
        }
    }

    private var playsOnSelect: Bool {
        row.kind == .continueWatching && settingsManager.interface.continueWatchingAction == .play
    }

    private func select(_ media: MediaDisplayItem) {
        if row.id == HomeRow.localContinueWatchingID,
           let item = media.playableItem,
           let mediaCardActions
        {
            mediaCardActions.resume(item)
        } else if playsOnSelect,
                  let item = media.playableItem,
                  let mediaCardActions
        {
            mediaCardActions.play(item, false)
        } else {
            onSelectMedia(media)
        }
    }

    private var canOpenViewAll: Bool {
        if canOpenWithoutServer {
            return row.hub.hasItems
        }
        #if os(tvOS)
            return row.hub.canShowViewAll
        #else
            return row.hub.canOpenDetail
        #endif
    }

    private var carouselViewAllAction: (() -> Void)? {
        #if os(tvOS)
            canOpenViewAll ? { onViewAll(row.hub) } : nil
        #else
            nil
        #endif
    }
}
