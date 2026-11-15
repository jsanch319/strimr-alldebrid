import SwiftUI

@MainActor
struct DiscoveryPersonalRows: View {
    @Environment(\.scenePhase) private var scenePhase
    private let discovery = DiscoveryStore.shared
    private let progress = CatalogProgressStore.shared
    private var records: [CatalogProgress] {
        _ = progress.revision
        return progress.records(scope: discovery.scope).filter { !$0.completed && $0.position > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                NavigationLink("Simkl Account") { TrackerSettingsView(service: .simkl) }
                Spacer()
                Button("Sync Simkl") { Task { await discovery.sync(force: true) } }.disabled(discovery.isSyncing)
            }
            if discovery.isSyncing {
                ProgressView("Syncing Simkl…")
            }
            if let error = discovery.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            progressRow("Continue Watching Movies", records: records.filter { $0.title.kind == .movie })
            progressRow("Continue Watching TV Shows", records: records.filter { $0.title.kind == .tv })
            if !discovery.nextUp.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Next Episodes · Simkl").font(.title2.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(discovery.nextUp.prefix(30)) { entry in
                                if let title = discovery.title(for: entry), let next = entry.nextEpisode {
                                    NavigationLink { TMDBDetailView(title: title, initialSeason: next.season) } label: {
                                        VStack(alignment: .leading) {
                                            poster(title)
                                            Text(title.displayTitle).lineLimit(2)
                                            Text("S\(next.season) E\(next.episode)").font(.caption)
                                                .foregroundStyle(.secondary)
                                        }.frame(width: 140)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            if !discovery.planned.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("My List · Simkl").font(.title2.bold())
                        Spacer()
                        NavigationLink("See All") { SimklMyListView() }
                    }
                    TMDBPosterRow(
                        heading: "",
                        titles: discovery.planned.prefix(30).compactMap { discovery.title(for: $0) },
                    )
                }
            }
        }
        .task(id: discovery.accountKey) { await discovery.sync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await discovery.sync() }
            }
        }
    }

    @ViewBuilder
    private func progressRow(_ heading: String, records: [CatalogProgress]) -> some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(heading).font(.title2.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(records) { record in
                            NavigationLink { TMDBDetailView(
                                title: record.title,
                                initialSeason: record.episode?.season_number,
                            ) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    poster(record.title)
                                    ProgressView(value: record.fraction).tint(.orange)
                                    Text(record.title.displayTitle).lineLimit(2)
                                    if let episode = record
                                        .episode
                                    {
                                        Text("S\(episode.season_number) E\(episode.episode_number)").font(.caption)
                                    }
                                    Text("Resume at \(Int(record.position / 60)) min").font(.caption)
                                        .foregroundStyle(.secondary)
                                }.frame(width: 140, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func poster(_ title: TMDBTitle) -> some View {
        TMDBArtwork(path: title.poster_path).frame(width: 140, height: 210).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct SimklMyListView: View {
    private let store = DiscoveryStore.shared
    var body: some View {
        List(store.planned) { entry in
            if let title = store.title(for: entry) {
                NavigationLink { TMDBDetailView(title: title) } label: { Text(title.displayTitle) }
            } else {
                VStack(alignment: .leading) {
                    Text(entry.media?.title ?? "Untitled")
                    Text("No TMDb mapping is available for this Simkl title.").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("My List · Simkl")
        .refreshable { await store.sync(force: true) }
    }
}
