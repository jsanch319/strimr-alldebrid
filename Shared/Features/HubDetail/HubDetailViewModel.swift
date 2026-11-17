import Foundation
import Observation

@MainActor
@Observable
final class HubDetailViewModel {
    let hub: Hub
    var items: [MediaDisplayItem] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let service: (any MediaHomeService)?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var nextOffset = 0
    var canLoadMore: Bool {
        !reachedEnd && service != nil
    }

    @ObservationIgnored private var totalItemCount: Int?
    @ObservationIgnored private let pageSize = 50

    init(hub: Hub, services: MediaServices, seedsLoadedItems: Bool = false) {
        self.hub = hub
        service = services.home
        if seedsLoadedItems {
            items = hub.items
            nextOffset = hub.items.count
            hasLoaded = true
            reachedEnd = !hub.hasMoreItems
        }
    }

    /// Already loaded catalog rows use the same hub UI without impersonating a media server.
    init(hub: Hub) {
        self.hub = hub
        service = nil
        items = hub.items
        hasLoaded = true
        reachedEnd = true
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        guard service != nil else { items = hub.items; reachedEnd = true; return }
        items = []
        reachedEnd = false
        totalItemCount = nil
        nextOffset = 0
        await loadPage(start: 0, isInitialLoad: true)
    }

    func loadMoreIfNeeded(currentItem item: MediaDisplayItem) async {
        guard item.id == items.last?.id else { return }
        await loadMore()
    }

    func loadMore() async {
        guard !items.isEmpty else { return }
        await loadPage(start: nextOffset, isInitialLoad: false)
    }

    private func loadPage(start: Int, isInitialLoad: Bool) async {
        guard !reachedEnd, !isLoading, !isLoadingMore, let service else { return }

        if isInitialLoad {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        errorMessage = nil
        defer {
            if isInitialLoad {
                isLoading = false
            } else {
                isLoadingMore = false
            }
        }

        do {
            let response = try await service.items(in: hub, startIndex: start, limit: pageSize)
            let newItems = response.items
            nextOffset = start + newItems.count
            totalItemCount = response.totalCount ?? totalItemCount

            if isInitialLoad {
                var seen = Set<String>()
                items = newItems.filter { seen.insert($0.id).inserted }
            } else {
                var seen = Set(items.map(\.id))
                items += newItems.filter { seen.insert($0.id).inserted }
            }

            if newItems.isEmpty {
                reachedEnd = true
            } else if let totalItemCount {
                reachedEnd = nextOffset >= totalItemCount
            }
        } catch {
            guard !Task.isCancelled, !error.isCancellation else { return }
            ErrorReporter.capture(error)
            errorMessage = String(localized: "hub.error.loadFailed")
            if isInitialLoad {
                items = []
            }
        }
    }
}
