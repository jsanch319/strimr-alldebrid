import Foundation
@testable import Strimr
import Testing

@MainActor
struct NativeHubPaginationTests {
    private final class Service: FakeMediaService {
        var offsets: [Int] = []
        var pageItems: [MediaDisplayItem] = []
        override func items(in _: Hub, startIndex: Int, limit _: Int) async throws -> MediaPage<MediaDisplayItem> {
            offsets.append(startIndex)
            return MediaPage(items: startIndex == 1 ? pageItems : [], startIndex: startIndex, totalCount: 4)
        }
    }

    @Test func `native rails seed existing cards and advance raw offsets while deduplicating posters`() async {
        let service = Service()
        let server = ServerIdentity(provider: .jellyfin, id: "test-server")
        let a = MediaDisplayItem.playable(MediaItem.make(id: "a", server: server))
        let b = MediaDisplayItem.playable(MediaItem.make(id: "b", server: server))
        service.pageItems = [a, b]
        let hub = Hub(
            id: "hub",
            key: "/items",
            hubKey: nil,
            title: "Test",
            size: 4,
            more: true,
            items: [a],
            server: server,
        )
        let model = HubDetailViewModel(hub: hub, services: .fake(service, server: server), seedsLoadedItems: true)
        await model.load() // Initial posters are already loaded, so no first-page replacement.
        #expect(service.offsets.isEmpty)
        await model.loadMore(); await model.loadMore(); await model.loadMore()
        #expect(service.offsets == [1, 3])
        #expect(model.items.map(\.id) == [a.id, b.id])
        #expect(!model.canLoadMore)
    }

    @Test func `finite hubs do not invent more provider requests`() async {
        let service = Service()
        let server = ServerIdentity(provider: .jellyfin, id: "test-server")
        let a = MediaDisplayItem.playable(MediaItem.make(id: "a", server: server))
        let hub = Hub(
            id: "hub",
            key: "/items",
            hubKey: nil,
            title: "Test",
            size: 1,
            more: false,
            items: [a],
            server: server,
        )
        let model = HubDetailViewModel(hub: hub, services: .fake(service, server: server), seedsLoadedItems: true)
        await model.loadMore()
        #expect(service.offsets.isEmpty)
        #expect(!model.canLoadMore)
    }
}
