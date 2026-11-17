import Foundation
@testable import Strimr
import Testing

@MainActor
struct CatalogTitlePagerTests {
    private func title(_ id: Int, kind: String = "movie") throws -> TMDBTitle {
        try JSONDecoder().decode(
            TMDBTitle.self,
            from: Data("{\"id\":\(id),\"media_type\":\"\(kind)\",\"title\":\"Title \(id)\"}".utf8),
        )
    }

    @Test func `pages append stable titles and stop at the API terminal page`() async throws {
        let a = try title(1), b = try title(2), tv = try title(1, kind: "tv")
        var requested: [Int] = []
        let pager = CatalogTitlePager { page in
            requested.append(page)
            return .init(results: page == 1 ? [a, b] : [b, tv], total_pages: 2)
        }
        await pager.loadNext(); await pager.loadNext(); await pager.loadNext()
        #expect(requested == [1, 2])
        #expect(pager.items.map(\.catalogID) == [a.catalogID, b.catalogID, tv.catalogID])
        #expect(!pager.hasMore)
    }

    @Test func `overlapping edge requests use a single in flight page`() async throws {
        let a = try title(1)
        var continuation: CheckedContinuation<TMDBClient.TitlePage, Never>?
        var requests = 0
        let pager = CatalogTitlePager { _ in
            requests += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = Task { await pager.loadNext() }
        while continuation == nil {
            await Task.yield()
        }
        await pager.loadNext()
        #expect(requests == 1)
        continuation?.resume(returning: .init(results: [a], total_pages: 1))
        await first.value
        #expect(pager.items.count == 1)
    }

    @Test func `refresh discards stale page responses without replacing newer results`() async throws {
        let old = try title(1), new = try title(2)
        var continuation: CheckedContinuation<TMDBClient.TitlePage, Never>?
        var requests = 0
        let pager = CatalogTitlePager { _ in
            requests += 1
            if requests == 1 {
                return await withCheckedContinuation { continuation = $0 }
            }
            return .init(results: [new], total_pages: 1)
        }
        let first = Task { await pager.loadNext() }
        while continuation == nil {
            await Task.yield()
        }
        pager.reset(); await pager.loadNext()
        continuation?.resume(returning: .init(results: [old], total_pages: 1))
        await first.value
        #expect(pager.items.map(\.id) == [2])
        #expect(pager.page == 1)
    }

    @Test func `rows have independent cursors and missing metadata ends on an empty page`() async throws {
        let a = try title(1)
        var firstPages: [Int] = [], secondPages: [Int] = []
        let first = CatalogTitlePager { page in
            firstPages.append(page); return .init(results: page == 1 ? [a] : [])
        }
        let second = CatalogTitlePager { page in
            secondPages.append(page); return .init(results: [a], total_pages: 4)
        }
        await first.loadNext(); await second.loadNext(); await first.loadNext(); await first.loadNext()
        #expect(firstPages == [1, 2]); #expect(secondPages == [1]); #expect(second.hasMore)
    }

    @Test func `recommendation seeds stop independently without repeated exhausted source calls`() async throws {
        let a = try title(1), b = try title(2)
        var requested: [String] = []
        let pager = CatalogTitlePager.recommendations(seeds: [a, b, a]) { title, page in
            requested.append("\(title.id):\(page)")
            return .init(results: [title], total_pages: title.id == 1 ? 1 : 3)
        }
        await pager.loadNext(); await pager.loadNext(); await pager.loadNext(); await pager.loadNext()
        #expect(requested == ["1:1", "2:1", "2:2", "2:3"])
        #expect(pager.items.map(\.id) == [1, 2])
        #expect(!pager.hasMore)
    }

    @Test func `rate limits retain posters and block repeated network attempts`() async throws {
        let a = try title(1)
        var requests = 0
        let pager = CatalogTitlePager { page in
            requests += 1
            if page == 2 {
                throw TMDBError.rateLimited(.distantFuture)
            }
            return .init(results: [a], total_pages: 2)
        }
        await pager.loadNext(); await pager.loadNext(); await pager.loadNext()
        #expect(requests == 2); #expect(pager.items.map(\.id) == [1]); #expect(pager.page == 1)
        #expect(pager.error != nil); #expect(!pager.loading)
    }
}
