import SwiftUI

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
    @Environment(SettingsManager.self) private var settingsManager
    let heading: String
    let titles: [TMDBTitle]
    @State private var selection: TMDBTitle?
    var body: some View {
        MediaHubSection(title: heading) {
            MediaCarousel(
                layout: .portrait,
                items: titles.map { .playable(CatalogMediaAdapter.make(title: $0, episode: nil, resume: nil)) },
                showsLabels: settingsManager.interface.showsCardLabels,
                onSelectMedia: { media in
                    selection = titles.first { $0.catalogID == media.id }
                },
            )
        }
        .navigationDestination(item: $selection) { TMDBDetailView(title: $0) }
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

@MainActor
struct TMDBSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    let onChanged: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("TMDb API Read Access Token") {
                    SecureField("Paste your read access token", text: $token)
                    Text(
                        "Create a TMDb account and request API access in Settings → API. The token is stored in this device’s Keychain.",
                    )
                    Link("TMDb API Settings", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    Button("Save Token") { update(remove: false) }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove Token", role: .destructive) { update(remove: true) }
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Image("tmdb").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 100, height: 44).accessibilityLabel("The Movie Database")
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    Link("The Movie Database", destination: URL(string: "https://www.themoviedb.org")!)
                }
            }
            .navigationTitle("TMDb Setup")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func update(remove: Bool) {
        do {
            if remove {
                try TMDBCredentialStore().delete()
            } else {
                try TMDBCredentialStore().save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            token = ""
            Task { await TMDBClient.shared.reset(); onChanged(); dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}
