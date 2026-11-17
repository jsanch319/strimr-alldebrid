#if DEBUG && os(iOS) && targetEnvironment(simulator)
    import Foundation

    /// Explicit XCUITest-only catalog transport. Never compiled into a device or Release build.
    /// Artwork still passes through the production image loader/cache using corresponding public TMDb URLs.
    nonisolated enum CatalogVisualFixtures {
        static var isEnabled: Bool {
            ProcessInfo.processInfo.arguments.contains("-CatalogVisualTesting")
        }

        private struct Payload: Decodable {
            let titles: [TMDBTitle]
            let episodes: [TMDBEpisode]
            let entries: [SimklListEntry]
        }

        private static let payload: Payload = {
            guard let json = ProcessInfo.processInfo.environment["STRIMR_VISUAL_FIXTURES"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data)
            else { preconditionFailure("Visual testing requires its isolated fixture payload") }
            return payload
        }()

        static var titles: [TMDBTitle] {
            payload.titles
        }

        static var entries: [SimklListEntry] {
            payload.entries
        }

        /// All requests terminate here in fixture mode; an unsupported request fails rather than using credentials.
        static func response(path: String, query: [URLQueryItem]) throws -> Data {
            let components = path.split(separator: "/").map(String.init)
            let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            let encoder = JSONEncoder()
            if components.last == "videos" {
                // Explicitly labeled UI fixture. The tests open the provider entry but never start playback.
                return Data(
                    #"{"results":[{"id":"visual-trailer","name":"Trailer UI fixture","site":"YouTube","key":"Way9Dexny3w","type":"Trailer","official":true,"iso_639_1":"en","size":1080}]}"#
                        .utf8,
                )
            }
            if components.count == 2, let id = Int(components[1]),
               let title = titles.first(where: { $0.kind.rawValue == components[0] && $0.id == id })
            {
                return try encoder.encode(title)
            }
            if components.count == 4, components[0] == "tv", components[2] == "season" {
                struct Episodes: Encodable { let episodes: [TMDBEpisode] }
                return try encoder.encode(Episodes(episodes: payload.episodes))
            }
            if path == "watch/providers/regions" {
                return Data(#"{"results":[{"iso_3166_1":"US","english_name":"United States"}]}"#.utf8)
            }
            if path.hasPrefix("watch/providers/") {
                let names = [
                    "Netflix",
                    "Disney Plus",
                    "HBO Max",
                    "Amazon Prime Video",
                    "Apple TV",
                    "Hulu",
                    "Paramount Plus",
                    "Peacock",
                    "Crunchyroll",
                ]
                let results = names.enumerated()
                    .map { ["provider_id": $0.offset + 1, "provider_name": $0.element] as [String: Any] }
                return try JSONSerialization.data(withJSONObject: ["results": results])
            }
            var results = titles
            if path == "search/multi" {
                let term = values["query"] ?? ""
                results = titles.filter { $0.displayTitle.localizedCaseInsensitiveContains(term) }
            } else if let kind = components.first(where: { $0 == "movie" || $0 == "tv" }) {
                results = titles.filter { $0.kind.rawValue == kind }
            } else {
                throw TMDBError.response(404)
            }
            if let genreID = values["with_genres"].flatMap(Int.init) {
                results = results.filter { $0.genres?.contains(where: { $0.id == genreID }) == true }
            }
            if components.last == "recommendations", components.count > 1, let id = Int(components[1]) {
                results.removeAll { $0.id == id }
            }
            if ProcessInfo.processInfo.environment["STRIMR_VISUAL_PAGINATION"] == "1", path == "trending/movie/week" {
                let page = Int(values["page"] ?? "1") ?? 1
                let split = page == 1 ? Array(results.prefix(3)) : page == 2 ? Array(results.suffix(2)) : []
                return try JSONSerialization.data(withJSONObject: [
                    "results": JSONSerialization.jsonObject(with: encoder.encode(split)), "total_pages": 2,
                ])
            }
            if let page = Int(values["page"] ?? "1"), page > 1 {
                results = []
            }
            struct Page: Encodable { let results: [TMDBTitle]; let total_results: Int; let total_pages: Int }
            return try encoder.encode(Page(results: results, total_results: results.count, total_pages: 1))
        }

        @MainActor
        static func seedProgress(_ store: CatalogProgressStore, scope: String) {
            guard store.records(scope: scope).isEmpty else { return }
            let paletteTesting = ProcessInfo.processInfo.environment["STRIMR_VISUAL_PROGRESS_COLORS"] == "1"
            let selected = paletteTesting
                ? [1_061_474, 27205, 693_134].compactMap { id in titles.first { $0.id == id } }
                : Array(titles.prefix(2))
            for (index, title) in selected.enumerated() {
                let episode = title.kind == .tv ? payload.episodes[1] : nil
                let duration = Double((episode?.runtime ?? title.runtimeMinutes ?? 55) * 60)
                store.save(
                    title: title,
                    episode: episode,
                    position: paletteTesting ? duration * 0.45 : index == 0 ? 7200.5 : 1200.25,
                    duration: duration,
                    finished: false,
                    scope: scope,
                )
            }
            var records = store.records(scope: scope)
            for index in records.indices {
                records[index].pendingSync = false
            }
            store.replace(records, scope: scope)
        }
    }
#endif
