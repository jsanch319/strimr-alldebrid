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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("tmdb.watchRegion") private var region = Locale.current.region?.identifier ?? "US"
    let title: TMDBTitle
    var initialSeason: Int?
    var initialEpisode: TMDBEpisode?
    @State private var selectedPlayback: PlaybackSelection?
    @State private var changingList = false
    @State private var changingWatched = false
    @State private var confirmRemoval = false
    @State private var detail: TMDBTitle?
    @State private var recommendations: [TMDBTitle] = []
    @State private var episodes: [TMDBEpisode] = []
    @State private var season: Int?
    @State private var selectedEpisode: TMDBEpisode?
    @State private var error: String?
    @State private var loadingEpisodes = false
    @State private var initialized = false
    @State private var expandedSynopsis = false
    private let discovery = DiscoveryStore.shared
    private let progress = CatalogProgressStore.shared
    private struct PlaybackSelection: Identifiable {
        let id = UUID()
        let episode: TMDBEpisode?
        var restart = false
    }

    init(title: TMDBTitle, initialSeason: Int? = nil, initialEpisode: TMDBEpisode? = nil) {
        self.title = title; self.initialSeason = initialSeason; self.initialEpisode = initialEpisode
        _selectedEpisode = State(initialValue: initialEpisode)
        _season = State(initialValue: initialSeason ?? initialEpisode?.season_number)
    }

    private var item: TMDBTitle {
        detail ?? title
    }

    private var records: [CatalogProgress] {
        _ = progress.revision; return progress.records(scope: discovery.scope)
    }

    private var saved: CatalogProgress? {
        CatalogDetailPlayback.savedRecord(
            title: item,
            episode: selectedEpisode,
            records: records,
        )
    }

    private var canPlay: Bool {
        item.kind == .movie || selectedEpisode != nil
    }

    private var resumes: Bool {
        CatalogDetailPlayback.resumes(saved)
    }

    private var watched: Bool {
        saved?.completed == true || (item.kind == .movie ? discovery.entry(for: item)?.status == "completed" :
            selectedEpisode.map { discovery.entry(for: item)?.watched(
                season: $0.season_number,
                episode: $0.episode_number,
            ) == true } ?? false)
    }

    private var actionSubtitle: String? {
        var parts: [String] = []
        if let episode = selectedEpisode {
            parts.append("S\(episode.season_number) · E\(episode.episode_number)")
        }
        if let remaining = CatalogDetailPlayback
            .remaining(title: item, episode: selectedEpisode, record: saved)
        {
            parts.append(remaining)
        }
        if item.kind == .tv, selectedEpisode == nil {
            parts.append("Choose an episode below")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                artworkSpace
                heading
                playbackActions
                trackingActions
                metadata
                synopsis
                genresAndStudio
                episodeSection
                if !recommendations.isEmpty {
                    TMDBPosterRow(heading: "Recommendations", titles: recommendations)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                if let syncError = discovery
                    .errorMessage
                {
                    Text(syncError).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, LayoutMetrics.pageMargin)
            .padding(.bottom, 28)
        }
        .catalogBackdrop(
            media: CatalogMediaAdapter.make(title: item, episode: nil, resume: nil),
            locked: true,
            details: true,
        )
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        #else
        .navigationTitle(item.displayTitle)
        #endif
        .sheet(item: $selectedPlayback, onDismiss: { Task { await discovery.sync(force: true) } }) { selection in
            CatalogSourcesView(title: item, episode: selection.episode, startsFromBeginning: selection.restart)
        }
        .confirmationDialog(
            "Remove this title from Simkl? This also clears its Simkl watch history and rating.",
            isPresented: $confirmRemoval,
            titleVisibility: .visible,
        ) {
            Button("Remove from Simkl", role: .destructive) { Task { await changeList(planned: false) } }
        }
        .task { await loadDetails() }
        .task(id: season) { await loadSeason() }
    }

    private var artworkSpace: some View {
        #if os(iOS)
            Color.clear.containerRelativeFrame(.vertical) { height, _ in min(max(height * 0.38, 240), 400) }
                .accessibilityHidden(true)
        #else
            TMDBArtwork(path: item.backdrop_path, backdrop: true).frame(height: 230).clipped()
        #endif
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.displayTitle).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if item.kind == .tv {
                let count = item.number_of_seasons ?? item.seasons?.filter { $0.season_number > 0 }.count
                if let count,
                   count > 0
                {
                    Text(count == 1 ? "1 season" : "\(count) seasons").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var playbackActions: some View {
        HStack(spacing: 12) {
            Button { selectedPlayback = PlaybackSelection(episode: selectedEpisode) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill").font(.title)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(resumes ? "Resume" : "Play").font(.title3.weight(.semibold))
                        if let subtitle = actionSubtitle {
                            Text(subtitle).font(.caption).lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .padding(.horizontal, 18).padding(.vertical, 15)
                .foregroundStyle(Color.background)
                .background(Color.textPrimary, in: Capsule())
            }
            .buttonStyle(.plain).disabled(!canPlay)
            .accessibilityLabel("\(resumes ? "Resume" : "Play") \(item.displayTitle)")
            .accessibilityHint(actionSubtitle ?? "Select an available playback source")
            if let saved, saved.locallyCleared != true, saved.position > 0 || saved.fraction > 0 {
                Button { selectedPlayback = PlaybackSelection(episode: selectedEpisode, restart: true) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.title2.weight(.medium))
                        .frame(width: 64, height: 64).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain).disabled(!canPlay)
                .accessibilityLabel(
                    "Restart \(selectedEpisode.map { "S\($0.season_number) E\($0.episode_number)" } ?? item.displayTitle) from beginning",
                )
            }
        }
    }

    private var trackingActions: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 30) {
                Button { Task { await markWatched() } } label: {
                    actionIcon(
                        watched ? "checkmark.circle.fill" : "checkmark.circle",
                        label: watched ? "Watched" :
                            (item.kind == .tv ? "Mark episode\nas watched" : "Mark as\nwatched"),
                    )
                }
                .disabled(watched || !canPlay || changingWatched || changingList || TrackerCoordinator.shared
                    .simklLibraryClient == nil)
                let planned = discovery.entry(for: item)?.isPlanned == true
                Button {
                    if planned {
                        confirmRemoval = true
                    } else {
                        Task { await changeList(planned: true) }
                    }
                } label: {
                    actionIcon(
                        planned ? "bookmark.fill" : "bookmark",
                        label: planned ? "In watchlist" : "Add to\nwatchlist",
                    )
                }.disabled(changingList || changingWatched || TrackerCoordinator.shared.simklLibraryClient == nil)
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity)
            if changingList || changingWatched {
                ProgressView()
            }
            if TrackerCoordinator.shared.simklLibraryClient == nil {
                NavigationLink("Connect Simkl for watchlist and watched status") { TrackerSettingsView(service: .simkl)
                }
                .font(.footnote)
            }
        }
    }

    private func actionIcon(_ symbol: String, label: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.title2).frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
            Text(label).font(.caption).multilineTextAlignment(.center)
        }
    }

    private var metadata: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                if let year = Int(item.date.prefix(4)) {
                    fact(String(year))
                }
                if let minutes = selectedEpisode?.runtime ?? item.runtimeMinutes, minutes > 0 {
                    fact(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m", symbol: "clock")
                }
                if let rating = item.vote_average,
                   rating > 0
                {
                    fact(String(format: "%.1f", rating), symbol: "star.fill")
                }
                if let certification = item.certification(in: region) {
                    fact(certification)
                }
            }
        }
    }

    private func fact(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }.font(.subheadline).padding(.horizontal, 11).padding(.vertical, 7).background(
            .ultraThinMaterial,
            in: Capsule(),
        )
    }

    private var synopsis: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tagline = item.tagline, !tagline.isEmpty {
                Text(tagline).font(.headline)
            }
            Text(item.overview ?? "No synopsis available.").foregroundStyle(.secondary)
                .lineLimit(expandedSynopsis ? nil : 4)
            if let overview = item.overview, !overview.isEmpty {
                Button(expandedSynopsis ? "Read less" : "Read more") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expandedSynopsis.toggle() }
                }.buttonStyle(.plain).fontWeight(.semibold)
            }
        }
    }

    private var genresAndStudio: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let genres = item.genres, !genres.isEmpty {
                Text("Genres").font(.headline)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8,
                ) {
                    ForEach(genres, id: \.id) { genre in fact(genre.name) }
                }
            }
            if let companies = item.production_companies, !companies.isEmpty {
                Text("STUDIO").font(.caption).foregroundStyle(.secondary)
                Text(companies.map(\.name).joined(separator: " · "))
            } else if let networks = item.networks, !networks.isEmpty {
                Text("NETWORK").font(.caption).foregroundStyle(.secondary)
                Text(networks.map(\.name).joined(separator: " · "))
            }
        }
    }

    @ViewBuilder private var episodeSection: some View {
        if let seasons = item.seasons, !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Text("Seasons and Episodes").font(.title2.bold())
                Picker("Season", selection: $season) {
                    Text("Select a season").tag(Int?.none)
                    ForEach(seasons) { season in
                        Text("\(season.name) (\(season.episode_count) episodes)").tag(Optional(season.season_number))
                    }
                }
                if loadingEpisodes {
                    ProgressView("Loading episodes…")
                }
                ForEach(episodes) { episode in episodeCard(episode) }
            }
        }
    }

    private func episodeCard(_ episode: TMDBEpisode) -> some View {
        let record = CatalogDetailPlayback.savedRecord(title: item, episode: episode, records: records)
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(episode.episode_number). \(episode.name)").font(.headline)
            if let path = episode
                .still_path
            {
                TMDBArtwork(path: path, backdrop: true).frame(height: 160).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if let date = episode.air_date {
                Text(date).font(.caption).foregroundStyle(.secondary)
            }
            Text(episode.overview ?? "").font(.subheadline).foregroundStyle(.secondary)
            if record?.completed == true || discovery.entry(for: item)?.watched(
                season: episode.season_number,
                episode: episode.episode_number,
            ) == true {
                Label("Watched · Simkl", systemImage: "checkmark.circle.fill").font(.caption)
            }
            Button {
                selectedEpisode = episode
                selectedPlayback = PlaybackSelection(episode: episode)
            } label: {
                Label(
                    CatalogDetailPlayback.resumes(record) ? "Resume Episode" : "Play Episode",
                    systemImage: "play.fill",
                )
            }.buttonStyle(.bordered)
            if let remaining = CatalogDetailPlayback.remaining(title: item, episode: episode, record: record) {
                Text(remaining).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }

    private func changeList(planned: Bool) async {
        changingList = true
        defer { changingList = false }
        do { try await discovery.setPlanned(item, planned: planned) }
        catch { self.error = "Simkl could not update My List. \(error.localizedDescription)" }
    }

    private func markWatched() async {
        changingWatched = true
        defer { changingWatched = false }
        do { try await discovery.markWatched(item, episode: selectedEpisode) }
        catch { self.error = "Simkl could not mark this title as watched. \(error.localizedDescription)" }
    }

    private func loadDetails() async {
        let firstLoad = !initialized
        initialized = true
        await discovery.sync()
        if firstLoad, item.kind == .tv, selectedEpisode == nil {
            let eligible = records.filter { season == nil || $0.episode?.season_number == season }
            selectedEpisode = CatalogDetailPlayback.latestEpisode(title: item, records: eligible)
            if season == nil {
                season = selectedEpisode?.season_number
            }
        }
        do {
            detail = try await TMDBClient.shared.details(title)
            if firstLoad, item.kind == .tv, season == nil {
                season = discovery.entry(for: item)?.nextEpisode?.season
                    ?? item.seasons?.first { $0.season_number > 0 }?.season_number
                    ?? item.seasons?.first?.season_number
            }
        } catch { self.error = error.localizedDescription }
        do { recommendations = try await TMDBClient.shared.recommendations(title) }
        catch { self.error = error.localizedDescription }
    }

    private func loadSeason() async {
        episodes = []
        guard let season else { selectedEpisode = nil; loadingEpisodes = false; return }
        if selectedEpisode?.season_number != season {
            selectedEpisode = nil
        }
        loadingEpisodes = true
        defer {
            if self.season == season {
                loadingEpisodes = false
            }
        }
        do {
            let loaded = try await TMDBClient.shared.episodes(tvID: title.id, season: season)
            try Task.checkCancellation()
            guard self.season == season else { return }
            episodes = loaded
            if let selected = selectedEpisode {
                selectedEpisode = loaded.first { $0.episode_number == selected.episode_number } ?? selected
            } else {
                let next = discovery.entry(for: item)?.nextEpisode
                selectedEpisode = loaded.first { next?.season == season && $0.episode_number == next?.episode }
                    ?? loaded
                    .first {
                        discovery.entry(for: item)?.watched(season: season, episode: $0.episode_number) != true
                    }
                    ?? loaded.first
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
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
            .catalogBackdropDisabled()
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
