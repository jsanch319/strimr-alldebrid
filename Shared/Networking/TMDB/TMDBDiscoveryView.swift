import SwiftUI

@MainActor
struct TMDBDiscoveryView: View {
    @State private var rows: [TMDBClient.Feed: [TMDBTitle]] = [:]
    @State private var results: [TMDBTitle] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false
    @State private var configuring = false
    @State private var token = ""
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Discover").font(.largeTitle.bold())
                Spacer()
                Button("TMDb Settings") { configuring = true }
            }
            DiscoveryPersonalRows()
            TextField("Search movies and TV shows", text: $query)
                .padding(12)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            if loading {
                ProgressView("Loading TMDb…")
            }
            if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { revision += 1 }
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let hero = rows[.trendingMovies]?.first {
                    NavigationLink { TMDBDetailView(title: hero) } label: {
                        ZStack(alignment: .bottomLeading) {
                            TMDBArtwork(path: hero.backdrop_path, backdrop: true)
                                .frame(height: 230).clipped()
                            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                            Text(hero.displayTitle).font(.title.bold()).foregroundStyle(.white).padding()
                        }.clipShape(RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                }
                ForEach(TMDBClient.Feed.allCases) { feed in
                    if let titles = rows[feed], !titles.isEmpty {
                        TMDBPosterRow(heading: feed.title, titles: titles)
                    }
                }
            } else {
                TMDBPosterRow(heading: "Search Results", titles: results)
                if !loading, results.isEmpty, error == nil {
                    Text("No movies or TV shows found.")
                }
            }
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption).foregroundStyle(.secondary)
            Link("The Movie Database", destination: URL(string: "https://www.themoviedb.org")!)
        }
        .task(id: "\(revision):\(query)") { await load() }
        .sheet(isPresented: $configuring) {
            NavigationStack {
                Form {
                    Section("TMDb API Read Access Token") {
                        SecureField("Paste your read access token", text: $token)
                        Text(
                            "Create a TMDb account and request API access in Settings → API. The token is stored only in this device’s Keychain.",
                        )
                        Link("TMDb API Settings", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                        Button("Save Token") {
                            do {
                                let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !value.isEmpty else { throw TMDBError.missingToken }
                                try TMDBCredentialStore().save(value)
                                token = ""
                                Task { await TMDBClient.shared.reset(); revision += 1 }
                                configuring = false
                            } catch { self.error = error.localizedDescription }
                        }
                        Button("Remove Token", role: .destructive) {
                            do {
                                try TMDBCredentialStore().delete()
                                rows = [:]; results = []; token = ""
                                Task { await TMDBClient.shared.reset(); revision += 1 }
                                configuring = false
                            } catch { self.error = error.localizedDescription }
                        }
                        if let error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle("TMDb Setup")
                .toolbar { Button("Done") { token = ""; configuring = false } }
            }
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty {
                results = []
                try await Task.sleep(for: .milliseconds(350))
                let found = try await TMDBClient.shared.search(search)
                try Task.checkCancellation()
                results = found
            } else {
                for feed in TMDBClient.Feed.allCases {
                    let titles = try await TMDBClient.shared.feed(feed)
                    try Task.checkCancellation()
                    rows[feed] = titles
                }
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

struct TMDBArtwork: View {
    let path: String?
    var backdrop = false
    var body: some View {
        AsyncImage(url: TMDBImageService.imageURL(path: path, size: backdrop ? .w1280 : .w500)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.secondary.opacity(0.15)).overlay { Image(systemName: "film").foregroundStyle(.secondary) }
        }
    }
}

struct TMDBPosterRow: View {
    let heading: String
    let titles: [TMDBTitle]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(titles, id: \.catalogID) { title in
                        NavigationLink { TMDBDetailView(title: title) } label: {
                            VStack(alignment: .leading) {
                                TMDBArtwork(path: title.poster_path)
                                    .frame(width: 140, height: 210).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(title.displayTitle).font(.subheadline).lineLimit(2)
                                Text(String(title.date.prefix(4))).font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 140, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

@MainActor
struct TMDBDetailView: View {
    let title: TMDBTitle
    var initialSeason: Int?
    @State private var selectedPlayback: PlaybackSelection?
    @State private var changingList = false
    @State private var confirmRemoval = false
    private let discovery = DiscoveryStore.shared
    private struct PlaybackSelection: Identifiable {
        let id = UUID()
        let episode: TMDBEpisode?
    }

    @State private var detail: TMDBTitle?
    @State private var recommendations: [TMDBTitle] = []
    @State private var episodes: [TMDBEpisode] = []
    @State private var season: Int?
    @State private var error: String?
    @State private var loadingEpisodes = false
    private var item: TMDBTitle {
        detail ?? title
    }

    private func changeList(planned: Bool) async {
        changingList = true
        defer { changingList = false }
        do { try await discovery.setPlanned(item, planned: planned) }
        catch { self.error = "Simkl could not update My List. \(error.localizedDescription)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TMDBArtwork(path: item.backdrop_path, backdrop: true).frame(height: 230).clipped()
                Text(item.displayTitle).font(.largeTitle.bold())
                Text(item.date).foregroundStyle(.secondary)
                if let rating = item.vote_average {
                    Text("TMDb Rating: \(rating, specifier: "%.1f") / 10")
                }
                Text((item.genres ?? []).map(\.name).joined(separator: " • "))
                Text(item.overview ?? "No description available.")
                Text("TMDb \(item.kind.rawValue) ID: \(item.id)").font(.caption)
                if item.kind == .movie {
                    Button("Find Available Sources") { selectedPlayback = PlaybackSelection(episode: nil) }
                        .buttonStyle(.borderedProminent)
                }
                if TrackerCoordinator.shared.simklLibraryClient != nil {
                    let planned = discovery.entry(for: item)?.isPlanned == true
                    Button(planned ? "Remove from My List" : "Add to My List") {
                        if planned {
                            confirmRemoval = true
                        } else {
                            Task { await changeList(planned: true) }
                        }
                    }.disabled(changingList)
                    if discovery.entry(for: item)?.status == "completed" {
                        Label("Watched · Simkl", systemImage: "checkmark.circle.fill")
                    }
                } else {
                    NavigationLink("Connect Simkl for My List and tracking") { TrackerSettingsView(service: .simkl) }
                }
                if let seasons = item.seasons, !seasons.isEmpty {
                    Picker("Season", selection: $season) {
                        Text("Select a season").tag(Int?.none)
                        ForEach(seasons) { season in
                            Text("\(season.name) (\(season.episode_count) episodes)")
                                .tag(Optional(season.season_number))
                        }
                    }
                    if loadingEpisodes {
                        ProgressView("Loading episodes…")
                    }
                    ForEach(episodes) { episode in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(episode.episode_number). \(episode.name)").font(.headline)
                            if let path = episode.still_path {
                                TMDBArtwork(path: path, backdrop: true).frame(height: 160).clipped()
                            }
                            Text(episode.air_date ?? "Air date unknown").font(.caption)
                            if let runtime = episode.runtime {
                                Text("Runtime: \(runtime) min").font(.caption)
                            }
                            if let rating = episode
                                .vote_average
                            {
                                Text("TMDb Rating: \(rating, specifier: "%.1f") / 10").font(.caption)
                            }
                            Text(episode.overview ?? "").font(.subheadline).foregroundStyle(.secondary)
                            if discovery.entry(for: item)?.watched(
                                season: episode.season_number,
                                episode: episode.episode_number,
                            ) == true {
                                Label("Watched · Simkl", systemImage: "checkmark.circle.fill")
                            }
                            Button("Find Available Sources") { selectedPlayback = PlaybackSelection(episode: episode) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if !recommendations.isEmpty {
                    TMDBPosterRow(heading: "Recommendations", titles: recommendations)
                }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                }
            }.padding()
        }
        .navigationTitle(item.displayTitle)
        .sheet(item: $selectedPlayback, onDismiss: { Task { await discovery.sync(force: true) } }) { selection in
            CatalogSourcesView(title: item, episode: selection.episode)
        }
        .confirmationDialog(
            "Remove this title from Simkl? This also clears its Simkl watch history and rating.",
            isPresented: $confirmRemoval,
            titleVisibility: .visible,
        ) {
            Button("Remove from Simkl", role: .destructive) { Task { await changeList(planned: false) } }
        }
        .task {
            season = initialSeason
            await discovery.sync()
            do {
                detail = try await TMDBClient.shared.details(title)
                recommendations = try await TMDBClient.shared.recommendations(title)
            } catch { self.error = error.localizedDescription }
        }
        .task(id: season) {
            episodes = []
            guard let season else { return }
            loadingEpisodes = true
            defer { loadingEpisodes = false }
            do {
                let loaded = try await TMDBClient.shared.episodes(tvID: title.id, season: season)
                try Task.checkCancellation()
                episodes = loaded
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
