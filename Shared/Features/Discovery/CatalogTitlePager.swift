import Foundation
import Observation

/// One request stream per row. Stable IDs are appended; refresh invalidates in-flight responses.
@MainActor @Observable
final class CatalogTitlePager {
    private(set) var items: [TMDBTitle] = []
    private(set) var page = 0
    private(set) var hasMore = true
    private(set) var loading = false
    private(set) var error: String?
    private var generation = UUID()
    private var retryAt = Date.distantPast
    private let loader: (Int) async throws -> TMDBClient.TitlePage

    init(loader: @escaping (Int) async throws -> TMDBClient.TitlePage) {
        self.loader = loader
    }

    func reset() {
        generation = UUID(); items = []; page = 0; hasMore = true; loading = false; error = nil
        retryAt = .distantPast
    }

    func loadNext() async {
        guard !loading, hasMore, Date() >= retryAt else { return }
        let request = generation
        loading = true; error = nil
        defer {
            if request == generation {
                loading = false
            }
        }
        do {
            let result = try await loader(page + 1)
            try Task.checkCancellation()
            guard request == generation else { return }
            var seen = Set(items.map(\.catalogID))
            items += result.results.filter { seen.insert($0.catalogID).inserted }
            page += 1
            hasMore = !result.results.isEmpty && page < min(result.total_pages ?? 500, 500)
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            if case let TMDBError.rateLimited(date) = error {
                retryAt = date
            } else {
                retryAt = Date().addingTimeInterval(3)
            }
        }
    }

    var pagination: PosterRailPagination {
        PosterRailPagination(hasMore: hasMore, loading: loading, error: error, loadMore: { await self.loadNext() })
    }
}

struct PosterRailPagination {
    let hasMore: Bool
    let loading: Bool
    let error: String?
    let loadMore: () async -> Void
}
