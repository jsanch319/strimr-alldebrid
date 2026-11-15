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
    private(set) var recommendations: [TMDBTitle] = []
    private(set) var isSearching = false
    private(set) var hasMoreSearchResults = false
    private var searchPage = 0
    private var searchQuery = ""
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
    private var loadTask: Task<Void, Never>?

    var progressRecords: [CatalogProgress] {
        _ = progress.revision
        return progress.records(scope: discovery.scope)
            .filter { !$0.completed && $0.locallyCleared != true && ($0.fraction > 0 || $0.position > 0) }
    }

    var rows: [HomeRow] {
        var rows: [HomeRow] = []
        let items = progressRecords.sorted { $0.updatedAt > $1.updatedAt }.map { record in
            let duration = record.duration ?? (record.episode?.runtime ?? record.title.runtime).map { Double($0) * 60 }
            let offset = !record.usesExactPosition && record.remotePercentage != nil
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
        rows.append(Self.row(id: "catalog:recommended", title: "Recommended For You", items: recommendations.map {
            CatalogMediaAdapter.make(title: $0, episode: nil, resume: nil)
        }))
        for kind in [TMDBTitle.Kind.movie, .tv] {
            let unwatched = discovery.entries.filter { entry in
                entry.kind == kind && ["plantowatch", "watching", "hold"].contains(entry.status ?? "")
                    && (kind == .movie || (entry.last_watched_at == nil
                            &&
                            (entry.watched_episodes_count ?? entry.seasons?
                                .reduce(0) { $0 + ($1.episodes?.count ?? 0) } ?? 0) == 0))
            }.compactMap { discovery.title(for: $0) }
            rows.append(Self.row(
                id: "catalog:unwatched:\(kind.rawValue)",
                title: kind == .movie ? "Unwatched Movies" : "Unwatched TV Shows",
                items: unwatched
                    .map { CatalogMediaAdapter.make(title: $0, episode: nil, resume: nil) },
            ))
        }
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
        for title in feeds.values.flatMap(\.self) + searchResults + recommendations + discovery.entries
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
        if let loadTask {
            await loadTask.value; return
        }
        let task = Task { await performLoad(force: force) }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad(force: Bool) async {
        errorMessage = nil
        await discovery.sync(force: force)
        recommendations = []
        // Personalization comes only from this account's actual watch history, never synthetic seeds.
        let seeds = discovery.entries.filter { $0.status == "completed" || $0.last_watched_at != nil }
            .sorted { ($0.last_watched_at ?? "") > ($1.last_watched_at ?? "") }.prefix(2)
        let known = Set(discovery.entries.compactMap(\.catalogID))
        var seen = known
        for entry in seeds {
            guard let title = discovery.title(for: entry) else { continue }
            do {
                let results = try await TMDBClient.shared.recommendations(title)
                recommendations += results.filter { seen.insert($0.catalogID).inserted }
            } catch { errorMessage = error.localizedDescription }
        }
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
        errorMessage = nil
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = []; searchPage = 0; hasMoreSearchResults = false
        guard !searchQuery.isEmpty else { isSearching = false; return }
        let requested = searchQuery
        do {
            isSearching = true
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            await searchMore(query: requested)
        } catch {
            if requested == searchQuery {
                isSearching = false
            }
        }
    }

    func searchMore(query: String? = nil) async {
        guard query != nil || !isSearching else { return }
        let requested = query ?? searchQuery
        guard !requested.isEmpty, requested == searchQuery else { return }
        isSearching = true
        defer {
            if requested == searchQuery {
                isSearching = false
            }
        }
        do {
            let result = try await TMDBClient.shared.search(requested, page: searchPage + 1)
            try Task.checkCancellation()
            guard requested == searchQuery else { return }
            var seen = Set(searchResults.map(\.catalogID))
            searchResults += result.filter { seen.insert($0.catalogID).inserted }
            searchPage += 1
            hasMoreSearchResults = !result.isEmpty && searchPage < 500
        } catch {
            if !Task.isCancelled, requested == searchQuery {
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
