import Foundation
import Observation

/// Supplies the original HomeView with provider-independent rows. It owns no card, spacing, color or player UI.
@MainActor
@Observable
final class CatalogHomeData {
    struct Selection: Identifiable, Hashable {
        let title: TMDBTitle
        let episode: TMDBEpisode?
        var id: String {
            CatalogProgress.key(title: title, episode: episode)
        }
    }

    private(set) var feeds: [TMDBClient.Feed: [TMDBTitle]] = [:]
    private(set) var files: [AllDebridMagnetFile] = []
    private(set) var links: [AllDebridSavedLink] = []
    private(set) var errorMessage: String?
    private(set) var searchResults: [TMDBTitle] = []
    private let discovery: DiscoveryStore
    private let progress: CatalogProgressStore
    init(
        discovery: DiscoveryStore? = nil,
        progress: CatalogProgressStore? = nil,
        feeds: [TMDBClient.Feed: [TMDBTitle]] = [:],
    ) {
        self.discovery = discovery ?? .shared
        self.progress = progress ?? .shared
        self.feeds = feeds
    }

    private var loaded = false

    var progressRecords: [CatalogProgress] {
        _ = progress.revision
        return progress.records(scope: discovery.scope).filter { !$0.completed && ($0.fraction > 0 || $0.position > 0) }
    }

    var rows: [HomeRow] {
        var rows: [HomeRow] = []
        let items = progressRecords.sorted { $0.updatedAt > $1.updatedAt }.map { record in
            let duration = record.duration ?? (record.episode?.runtime ?? record.title.runtime).map { Double($0) * 60 }
            let offset = record.pendingSync == false && record.remotePercentage != nil
                ? duration.map { $0 * record.fraction } : record.position
            return CatalogMediaAdapter.make(
                title: record.title,
                episode: record.episode,
                resume: offset,
                duration: duration,
            )
        }
        rows.append(Self.row(
            id: "catalog:continue",
            title: "Continue Watching",
            kind: .continueWatching,
            style: .landscape,
            items: items,
        ))
        let next = discovery.nextUp.compactMap { entry -> MediaItem? in
            guard let title = discovery.title(for: entry), let next = entry.nextEpisode else { return nil }
            let episode = TMDBEpisode(
                id: -1,
                episode_number: next.episode,
                season_number: next.season,
                name: "",
                overview: nil,
                air_date: nil,
                still_path: nil,
                runtime: nil,
                vote_average: nil,
            )
            return CatalogMediaAdapter.make(title: title, episode: episode, resume: nil)
        }
        rows.append(Self.row(id: "catalog:next", title: "Next Episodes", kind: .nextUp, items: next))
        rows.append(Self.row(
            id: "catalog:list",
            title: "My List",
            items: discovery.planned.compactMap { discovery.title(for: $0) }.map { CatalogMediaAdapter.make(
                title: $0,
                episode: nil,
                resume: nil,
            ) },
        ))
        for feed in TMDBClient.Feed.allCases {
            rows.append(Self.row(
                id: "catalog:\(feed.id)",
                title: feed.title,
                items: (feeds[feed] ?? []).map { CatalogMediaAdapter.make(title: $0, episode: nil, resume: nil) },
            ))
        }
        return rows.filter(\.hub.hasItems)
    }

    func heroSlides(source: HomeHeroSource, includesTrending: Bool = true) -> [HomeHeroSlide] {
        switch source {
        case .off: return []
        case .continueWatching: return rows.filter { $0.kind == .continueWatching }.flatMap(\.items)
            .compactMap(\.playableItem)
            .prefix(HomeHeroSlides.resumeLimit).map { HomeHeroSlide(
                media: $0,
                badge: .resume,
            ) }
        case .discover:
            let movies = feeds[includesTrending ? .trendingMovies : .popularMovies] ?? []
            let shows = feeds[includesTrending ? .trendingTV : .popularTV] ?? []
            var featured: [TMDBTitle] = []
            for index in 0 ..< max(movies.count, shows.count) {
                if index < movies.count {
                    featured.append(movies[index])
                }
                if index < shows.count {
                    featured.append(shows[index])
                }
            }
            return featured.prefix(FeaturedAggregation.defaultCount).map { HomeHeroSlide(
                media: CatalogMediaAdapter.make(title: $0, episode: nil, resume: nil),
                badge: .featured(includesTrending ? .trending : .curated, newSeasonNumber: nil, collectionTitle: nil),
            ) }
        }
    }

    func selection(for media: MediaItem) -> Selection? {
        if let record = progressRecords.first(where: { $0.id == media.id }) {
            return Selection(
                title: record.title,
                episode: record.episode,
            )
        }
        for title in feeds.values.flatMap(\.self) + searchResults + discovery.entries
            .compactMap({ discovery.title(for: $0) })
        {
            if title.catalogID == media.id {
                return Selection(title: title, episode: nil)
            }
            if let next = discovery.nextUp.first(where: { $0.catalogID == title.catalogID })?.nextEpisode,
               media.id == "\(title.catalogID):s\(next.season):e\(next.episode)"
            {
                return Selection(
                    title: title,
                    episode: TMDBEpisode(
                        id: -1,
                        episode_number: next.episode,
                        season_number: next.season,
                        name: "",
                        overview: nil,
                        air_date: nil,
                        still_path: nil,
                        runtime: nil,
                        vote_average: nil,
                    ),
                )
            }
        }
        return nil
    }

    func rawSelection(for media: MediaItem) -> AllDebridHomeItem? {
        if let file = files.first(where: { media.id == "magnet:\($0.id)" }) {
            return .magnetFile(file)
        }
        if let link = links.first(where: { media.id == "saved:\($0.id)" }) {
            return .savedLink(link)
        }
        return nil
    }

    func load(force: Bool = false) async {
        errorMessage = nil
        await discovery.sync(force: force)
        if !loaded || force {
            do {
                for feed in TMDBClient.Feed.allCases {
                    feeds[feed] = try await TMDBClient.shared.feed(feed)
                }
                loaded = true
            } catch { errorMessage = error.localizedDescription }
            do {
                if let key = try AllDebridCredentialStore().load() {
                    let snapshot = try await AllDebridAPIClient(apiKey: key).librarySnapshot()
                    files = snapshot.magnetFiles; links = snapshot.savedLinks
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func search(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searchResults = []; return }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let results = try await TMDBClient.shared.search(query)
            try Task.checkCancellation()
            searchResults = results
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    var searchRow: HomeRow {
        Self.row(
            id: "catalog:search",
            title: "Search Results",
            items: searchResults.map { CatalogMediaAdapter.make(title: $0, episode: nil, resume: nil) },
        )
    }

    private static func row(
        id: String,
        title: String,
        kind: HomeRowKind = .hub,
        style: HomeRowStyle = .portrait,
        items: [MediaItem],
    ) -> HomeRow {
        HomeRow(
            id: id,
            kind: kind,
            style: style,
            hub: Hub(
                id: id,
                key: "",
                hubKey: nil,
                title: title,
                size: items.count,
                more: false,
                items: items.map(MediaDisplayItem.playable),
            ),
        )
    }
}
