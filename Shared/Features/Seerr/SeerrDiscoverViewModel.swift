import Foundation
import Observation

@MainActor
@Observable
final class SeerrDiscoverViewModel {
    @ObservationIgnored private let store: SeerrStore
    @ObservationIgnored private let permissionService = SeerrPermissionService()
    @ObservationIgnored private var refreshGate = AutomaticRefreshGate()

    var trending: [SeerrMedia] = []
    var popularMovies: [SeerrMedia] = []
    var popularTV: [SeerrMedia] = []
    var upcomingMovies: [SeerrMedia] = []
    var upcomingTV: [SeerrMedia] = []
    var isLoading = false
    var errorMessage: String?
    var pendingRequestsCount = 0
    private var rowPages: [String: Int] = [:]
    private var rowTotals: [String: Int] = [:]
    private var pagingRows: Set<String> = []
    private var pagingErrors: [String: String] = [:]
    private var pagingGeneration = UUID()

    func pagination(for key: String) -> PosterRailPagination {
        PosterRailPagination(
            hasMore: (rowPages[key] ?? 0) < (rowTotals[key] ?? 0),
            loading: pagingRows.contains(key),
            error: pagingErrors[key],
            loadMore: { await self.loadNext(key) },
        )
    }

    private func rowItems(_ key: String) -> [SeerrMedia] {
        switch key {
        case "trending": trending
        case "popularMovies": popularMovies
        case "popularTV": popularTV
        case "upcomingMovies": upcomingMovies
        default: upcomingTV
        }
    }

    private func setRow(_ key: String, items: [SeerrMedia]) {
        switch key {
        case "trending": trending = items
        case "popularMovies": popularMovies = items
        case "popularTV": popularTV = items
        case "upcomingMovies": upcomingMovies = items
        default: upcomingTV = items
        }
    }

    private func firstPage(_ response: SeerrPaginatedResponse<SeerrMedia>, key: String, preserving: Bool) {
        guard !preserving || (rowPages[key] ?? 0) <= 1 else { return }
        var seen = Set<String>()
        setRow(key, items: response.results.filter { seen.insert($0.posterPagingID).inserted })
        rowPages[key] = response.page
        rowTotals[key] = min(500, response.totalPages)
    }

    private func loadNext(_ key: String) async {
        guard let baseURL, isLoggedIn, !pagingRows.contains(key),
              let page = rowPages[key], page < (rowTotals[key] ?? 0) else { return }
        let generation = pagingGeneration
        pagingRows.insert(key); pagingErrors[key] = nil
        defer {
            if generation == pagingGeneration {
                pagingRows.remove(key)
            }
        }
        do {
            let repository = SeerrDiscoverRepository(baseURL: baseURL)
            let response: SeerrPaginatedResponse<SeerrMedia>
            let date = Self.upcomingDateFormatter.string(from: Date())
            switch key {
            case "trending": response = try await repository.getTrending(page: page + 1)
            case "popularMovies": response = try await repository.discoverMovies(page: page + 1)
            case "popularTV": response = try await repository.discoverTV(page: page + 1)
            case "upcomingMovies": response = try await repository.discoverMovies(
                    page: page + 1,
                    primaryReleaseDateGte: date,
                )
            default: response = try await repository.discoverTV(page: page + 1, firstAirDateGte: date)
            }
            try Task.checkCancellation()
            guard generation == pagingGeneration, baseURL == self.baseURL else { return }
            var items = rowItems(key)
            var seen = Set(items.map(\.posterPagingID))
            items += response.results.filter { seen.insert($0.posterPagingID).inserted }
            setRow(key, items: items)
            rowPages[key] = page + 1
            rowTotals[key] = response.results.isEmpty ? page + 1 : min(500, response.totalPages)
        } catch {
            if !Task.isCancelled, generation == pagingGeneration {
                pagingErrors[key] = error.localizedDescription
            }
        }
    }

    init(store: SeerrStore) {
        self.store = store
    }

    var isLoggedIn: Bool {
        store.isLoggedIn
    }

    var hasContent: Bool {
        !trending.isEmpty
            || !popularMovies.isEmpty
            || !popularTV.isEmpty
            || !upcomingMovies.isEmpty
            || !upcomingTV.isEmpty
    }

    var canManageRequests: Bool {
        permissionService.hasPermission(.manageRequests, user: store.user)
    }

    func load() async {
        guard refreshGate.startInitialLoadIfNeeded() else { return }
        await fetch(preservingExistingContent: false)
    }

    func reload() async {
        pagingGeneration = UUID(); rowPages = [:]; rowTotals = [:]; pagingRows = []; pagingErrors = [:]
        trending = []
        popularMovies = []
        popularTV = []
        upcomingMovies = []
        upcomingTV = []
        await fetch(preservingExistingContent: false)
    }

    func refreshIfNeeded(now: Date = Date()) async {
        guard refreshGate.shouldRefresh(now: now, isLoading: isLoading) else { return }
        await fetch(preservingExistingContent: true)
    }

    private func fetch(preservingExistingContent: Bool) async {
        guard !isLoading, let baseURL else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let repository = SeerrDiscoverRepository(baseURL: baseURL)
            let trendingPage = try await repository.getTrending(page: 1)
            let moviesPage = try await repository.discoverMovies(page: 1)
            let tvPage = try await repository.discoverTV(page: 1)
            let upcomingDate = Self.upcomingDateFormatter.string(from: Date())
            let upcomingMoviesPage = try await repository.discoverMovies(
                page: 1,
                primaryReleaseDateGte: upcomingDate,
            )
            let upcomingTVPage = try await repository.discoverTV(
                page: 1,
                firstAirDateGte: upcomingDate,
            )

            firstPage(trendingPage, key: "trending", preserving: preservingExistingContent)
            firstPage(moviesPage, key: "popularMovies", preserving: preservingExistingContent)
            firstPage(tvPage, key: "popularTV", preserving: preservingExistingContent)
            firstPage(upcomingMoviesPage, key: "upcomingMovies", preserving: preservingExistingContent)
            firstPage(upcomingTVPage, key: "upcomingTV", preserving: preservingExistingContent)
        } catch {
            handleLoadError(preservingExistingContent: preservingExistingContent)
        }

        await loadRequestCount()
    }

    var requestsBadgeCount: Int {
        canManageRequests ? pendingRequestsCount : 0
    }

    private var baseURL: URL? {
        guard let baseURLString = store.baseURLString else { return nil }
        return URL(string: baseURLString)
    }

    private func loadRequestCount() async {
        guard canManageRequests else {
            pendingRequestsCount = 0
            return
        }
        guard let baseURL else { return }

        do {
            let repository = SeerrRequestRepository(baseURL: baseURL)
            let count = try await repository.getRequestCount()
            pendingRequestsCount = count.pending
        } catch {
            pendingRequestsCount = 0
        }
    }

    private static let upcomingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func handleLoadError(preservingExistingContent: Bool) {
        if preservingExistingContent, hasContent {
            errorMessage = nil
        } else {
            errorMessage = String(localized: .init("common.errors.tryAgainLater"))
        }
    }
}

extension SeerrMedia {
    var posterPagingID: String {
        "\(mediaType?.rawValue ?? "unknown"):\(id)"
    }
}
