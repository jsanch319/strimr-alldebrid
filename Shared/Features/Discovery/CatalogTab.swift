import SwiftUI

/// The six server-free destinations; More is only the native compact navigation container.
nonisolated enum CatalogTab: String, CaseIterable, Identifiable {
    case home, search, movies, tvShows, myList, settings, more
    var id: String {
        rawValue
    }

    static let destinations: [Self] = [.home, .search, .movies, .tvShows, .myList, .settings]
    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .movies: "Movies"
        case .tvShows: "TV Shows"
        case .myList: "My List"
        case .settings: "Settings"
        case .more: "More"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .movies: "film.fill"
        case .tvShows: "tv"
        case .myList: "bookmark.fill"
        case .settings: "gearshape.fill"
        case .more: "ellipsis"
        }
    }

    var feeds: [TMDBClient.Feed] {
        switch self {
        case .movies: [.trendingMovies, .popularMovies, .upcoming, .topMovies]
        case .tvShows: [.trendingTV, .popularTV, .topTV]
        default: []
        }
    }
}

nonisolated struct CatalogTabLayout: Equatable {
    let bar: [CatalogTab]
    let overflow: [CatalogTab]
    init(isCompact: Bool) {
        // Match MainTabView: four normal items including More, plus the dedicated Search role.
        bar = isCompact ? [.home, .search, .movies, .tvShows, .more] : CatalogTab.destinations
        overflow = isCompact ? [.myList, .settings] : []
    }
}

extension EnvironmentValues {
    @Entry var isCatalogNavigation = false
}
