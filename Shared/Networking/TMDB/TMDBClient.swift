import Foundation

/// A catalog identity is always the media type plus TMDb ID (movie and TV IDs can overlap).
nonisolated struct TMDBTitle: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case movie, tv }
    let id: Int
    var media_type: String?
    let title: String?
    let name: String?
    let overview: String?
    let poster_path: String?
    let backdrop_path: String?
    let release_date: String?
    let first_air_date: String?
    let vote_average: Double?
    let genres: [Genre]?
    let seasons: [Season]?
    let external_ids: RemoteIDs?
    let runtime: Int?
    struct AlternativeTitles: Codable, Hashable, Sendable {
        struct Entry: Codable, Hashable, Sendable { let title: String }
        let titles: [Entry]?
        let results: [Entry]?
    }

    var alternative_titles: AlternativeTitles? = nil
    var original_title: String? = nil
    var original_name: String? = nil
    var tagline: String? = nil
    var episode_run_time: [Int]? = nil
    var number_of_seasons: Int? = nil
    var production_companies: [Company]? = nil
    var networks: [Company]? = nil
    var content_ratings: ContentRatings? = nil
    var release_dates: ReleaseDates? = nil

    struct Company: Codable, Hashable, Sendable { let id: Int; let name: String }
    struct ContentRatings: Codable, Hashable, Sendable {
        struct Rating: Codable, Hashable, Sendable { let iso_3166_1: String; let rating: String }
        let results: [Rating]
    }

    struct ReleaseDates: Codable, Hashable, Sendable {
        struct Region: Codable, Hashable, Sendable {
            struct Release: Codable, Hashable, Sendable { let certification: String; let type: Int? }
            let iso_3166_1: String
            let release_dates: [Release]
        }

        let results: [Region]
    }

    func certification(in region: String) -> String? {
        if kind ==
            .tv
        {
            return content_ratings?.results.first { $0.iso_3166_1 == region && !$0.rating.isEmpty }?.rating
        }
        let releases = release_dates?.results.first { $0.iso_3166_1 == region }?.release_dates
            .filter { !$0.certification.isEmpty } ?? []
        return (releases.first { $0.type == 3 } ?? releases.first)?.certification
    }

    var runtimeMinutes: Int? {
        runtime.flatMap { $0 > 0 ? $0 : nil } ?? episode_run_time?.first { $0 > 0 }
    }

    struct Genre: Codable, Hashable, Sendable { let id: Int; let name: String }
    struct Season: Codable, Identifiable, Hashable, Sendable {
        let id: Int
        let season_number: Int
        let name: String
        let episode_count: Int
    }

    struct RemoteIDs: Codable, Hashable, Sendable { let imdb_id: String?; let tvdb_id: Int? }
    /// Reuses the app's identity format for Simkl and file/source matching.
    var matchingIDs: ExternalIDs {
        ExternalIDs(imdb: external_ids?.imdb_id, tmdb: String(id), tvdb: external_ids?.tvdb_id.map(String.init))
    }

    func trackerItem(episode: TMDBEpisode? = nil) -> TrackerItem? {
        switch (kind, episode) {
        case (.movie, nil):
            TrackerItem(kind: .movie, ids: matchingIDs, title: displayTitle, year: Int(date.prefix(4)))
        case let (.tv, episode?):
            TrackerItem(
                kind: .episode,
                ids: matchingIDs,
                title: displayTitle,
                year: Int(date.prefix(4)),
                season: episode.season_number,
                episode: episode.episode_number,
            )
        default:
            nil
        }
    }

    static func reference(id: Int, kind: Kind, title: String = "", year: Int? = nil) -> TMDBTitle {
        TMDBTitle(
            id: id,
            media_type: kind.rawValue,
            title: kind == .movie ? title : nil,
            name: kind == .tv ? title : nil,
            overview: nil,
            poster_path: nil,
            backdrop_path: nil,
            release_date: kind == .movie ? year.map(String.init) : nil,
            first_air_date: kind == .tv ? year.map(String.init) : nil,
            vote_average: nil,
            genres: nil,
            seasons: nil,
            external_ids: nil,
            runtime: nil,
        )
    }

    var kind: Kind {
        media_type == "tv" ? .tv : .movie
    }

    var catalogID: String {
        "\(kind.rawValue):\(id)"
    }

    var displayTitle: String {
        title ?? name ?? "Untitled"
    }

    var date: String {
        release_date ?? first_air_date ?? ""
    }
}

nonisolated struct TMDBEpisode: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let episode_number: Int
    let season_number: Int
    let name: String
    let overview: String?
    let air_date: String?
    let still_path: String?
    let runtime: Int?
    let vote_average: Double?
}

nonisolated enum TMDBError: LocalizedError {
    case missingToken, unauthorized, rateLimited(Date), response(Int)
    var errorDescription: String? {
        switch self {
        case .missingToken: "Add your TMDb API Read Access Token in TMDb settings."
        case .unauthorized: "TMDb rejected this token. Check your API Read Access Token."
        case let .rateLimited(date): "TMDb request limit reached. Try again after \(date.formatted(date: .omitted, time: .standard))."
        case let .response(code): "TMDb is unavailable (HTTP \(code)). Please retry."
        }
    }
}

/// Direct TMDb v3 access; never depends on a media server or Seerr.
actor TMDBClient {
    static let shared = TMDBClient()
    nonisolated enum Feed: String, CaseIterable, Identifiable {
        case trendingMovies, trendingTV, popularMovies, popularTV, upcoming, topMovies, topTV
        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .trendingMovies: "Trending Movies"
            case .trendingTV: "Trending TV Shows"
            case .popularMovies: "Popular Movies"
            case .popularTV: "Popular TV Shows"
            case .upcoming: "Upcoming Movies"
            case .topMovies: "Top Rated Movies"
            case .topTV: "Top Rated TV Shows"
            }
        }

        var path: String {
            switch self {
            case .trendingMovies: "trending/movie/week"
            case .trendingTV: "trending/tv/week"
            case .popularMovies: "movie/popular"
            case .popularTV: "tv/popular"
            case .upcoming: "movie/upcoming"
            case .topMovies: "movie/top_rated"
            case .topTV: "tv/top_rated"
            }
        }

        var kind: TMDBTitle.Kind {
            [.trendingTV, .popularTV, .topTV].contains(self) ? .tv : .movie
        }
    }

    nonisolated struct TitlePage: Decodable, Sendable {
        var results: [TMDBTitle]
        var total_pages: Int? = nil
    }

    private typealias Page = TitlePage
    private nonisolated struct Episodes: Decodable { let episodes: [TMDBEpisode] }
    private var cache: [String: (Date, Data)] = [:]
    private var retryAt: Date?
    private let session: URLSession
    private let tokenProvider: @Sendable () throws -> String?
    init(
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () throws -> String? = { try TMDBCredentialStore().load() },
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func reset() {
        cache.removeAll(); retryAt = nil
    }

    func feedPage(_ feed: Feed, page: Int) async throws -> TitlePage {
        try await titlePage(path: feed.path, kind: feed.kind, page: page)
    }

    func recommendationPage(_ title: TMDBTitle, page: Int) async throws -> TitlePage {
        try await titlePage(path: "\(title.kind.rawValue)/\(title.id)/recommendations", kind: title.kind, page: page)
    }

    nonisolated enum GenreSort: String, CaseIterable, Identifiable {
        case popular, topRated
        var id: Self {
            self
        }

        var title: String {
            self == .popular ? "Popular" : "Top Rated"
        }
    }

    func genreTitles(genreID: Int, kind: TMDBTitle.Kind, sort: GenreSort, page: Int) async throws -> TitlePage {
        var query = [
            URLQueryItem(name: "with_genres", value: String(genreID)),
            URLQueryItem(name: "sort_by", value: sort == .popular ? "popularity.desc" : "vote_average.desc"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        if sort == .topRated {
            query.append(URLQueryItem(name: "vote_count.gte", value: "100"))
        }
        var response: TitlePage = try await get("discover/\(kind.rawValue)", query: query)
        response.results = response.results.map { var title = $0; title.media_type = kind.rawValue; return title }
        return response
    }

    private func titlePage(path: String, kind: TMDBTitle.Kind, page: Int) async throws -> TitlePage {
        var response: TitlePage = try await get(path, query: [URLQueryItem(name: "page", value: String(page))])
        response.results = response.results.map { var title = $0; title.media_type = kind.rawValue; return title }
        return response
    }

    func feed(_ feed: Feed, page: Int = 1) async throws -> [TMDBTitle] {
        try await titles(path: feed.path, kind: feed.kind, page: page)
    }

    func search(_ query: String, page: Int = 1) async throws -> [TMDBTitle] {
        try await searchPage(query, page: page).results
    }

    func searchPage(_ query: String, page: Int) async throws -> TitlePage {
        var result: TitlePage = try await get("search/multi", query: [
            URLQueryItem(name: "query", value: query), URLQueryItem(name: "page", value: String(page)),
        ])
        result.results = result.results.filter { $0.media_type == "movie" || $0.media_type == "tv" }
        return result
    }

    func details(_ title: TMDBTitle) async throws -> TMDBTitle {
        var result: TMDBTitle = try await get(
            "\(title.kind.rawValue)/\(title.id)",
            query: [URLQueryItem(
                name: "append_to_response",
                value: title
                    .kind == .movie ? "external_ids,release_dates,alternative_titles" :
                    "external_ids,content_ratings,alternative_titles",
            )],
        )
        result.media_type = title.kind.rawValue
        return result
    }

    func find(imdb: String?, tvdb: String?, kind: TMDBTitle.Kind) async throws -> TMDBTitle? {
        struct Matches: Decodable { let movie_results: [TMDBTitle]; let tv_results: [TMDBTitle] }
        guard let identifier = imdb ?? tvdb else { return nil }
        let result: Matches = try await get(
            "find/\(identifier)",
            query: [URLQueryItem(name: "external_source", value: imdb == nil ? "tvdb_id" : "imdb_id")],
        )
        guard var title = (kind == .movie ? result.movie_results : result.tv_results).first else { return nil }
        title.media_type = kind.rawValue
        return title
    }

    func recommendations(_ title: TMDBTitle, page: Int = 1) async throws -> [TMDBTitle] {
        try await titles(path: "\(title.kind.rawValue)/\(title.id)/recommendations", kind: title.kind, page: page)
    }

    func episodes(tvID: Int, season: Int) async throws -> [TMDBEpisode] {
        let result: Episodes = try await get("tv/\(tvID)/season/\(season)")
        return result.episodes
    }

    nonisolated struct WatchProvider: Decodable, Sendable {
        let provider_id: Int
        let provider_name: String
        let logo_path: String?
    }

    nonisolated struct WatchRegion: Decodable, Identifiable, Sendable {
        let iso_3166_1: String
        let english_name: String
        var id: String {
            iso_3166_1
        }
    }

    nonisolated struct ProviderPage: Decodable, Sendable {
        var results: [TMDBTitle]
        let total_results: Int
        let total_pages: Int
    }

    func watchProviders(kind: TMDBTitle.Kind) async throws -> [WatchProvider] {
        struct Response: Decodable { let results: [WatchProvider] }
        let response: Response = try await get("watch/providers/\(kind.rawValue)")
        return response.results
    }

    func watchRegions() async throws -> [WatchRegion] {
        struct Response: Decodable { let results: [WatchRegion] }
        let response: Response = try await get("watch/providers/regions")
        return response.results.sorted { $0.english_name < $1.english_name }
    }

    func providerTitles(ids: [Int], kind: TMDBTitle.Kind, region: String, page: Int = 1) async throws -> ProviderPage {
        guard !ids.isEmpty else { return ProviderPage(results: [], total_results: 0, total_pages: 0) }
        var response: ProviderPage = try await get("discover/\(kind.rawValue)", query: [
            URLQueryItem(name: "with_watch_providers", value: ids.sorted().map(String.init).joined(separator: "|")),
            URLQueryItem(name: "watch_region", value: region),
            URLQueryItem(name: "with_watch_monetization_types", value: "flatrate"),
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
            URLQueryItem(name: "page", value: String(page)),
        ])
        response.results = response.results.map { var title = $0; title.media_type = kind.rawValue; return title }
        return response
    }

    private func titles(path: String, kind: TMDBTitle.Kind, page: Int) async throws -> [TMDBTitle] {
        let result: Page = try await get(path, query: [URLQueryItem(name: "page", value: String(page))])
        return result.results.map { var title = $0; title.media_type = kind.rawValue; return title }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
            if CatalogVisualFixtures.isEnabled {
                return try JSONDecoder().decode(T.self, from: CatalogVisualFixtures.response(path: path, query: query))
            }
        #endif
        guard let token = try tokenProvider(), !token.isEmpty else { throw TMDBError.missingToken }
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        components.queryItems = query + [
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en-US"),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        let url = components.url!
        let key = url.absoluteString
        if let (expiry, data) = cache[key], expiry > Date() {
            return try JSONDecoder().decode(T.self, from: data)
        }
        if let retryAt, retryAt > Date() {
            throw TMDBError.rateLimited(retryAt)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw TMDBError.response(0) }
        switch response.statusCode {
        case 200 ... 299: break
        case 401, 403: throw TMDBError.unauthorized
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let date = TimeInterval(header).map { Date().addingTimeInterval(max(1, $0)) } ?? formatter
                .date(from: header) ?? Date().addingTimeInterval(60)
            retryAt = date
            throw TMDBError.rateLimited(date)
        default: throw TMDBError.response(response.statusCode)
        }
        let decoded = try JSONDecoder().decode(T.self, from: data)
        if cache.count >= 150 {
            cache.removeAll()
        }
        cache[key] = (Date().addingTimeInterval(300), data)
        return decoded
    }
}
