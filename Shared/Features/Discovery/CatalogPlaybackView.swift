import AVKit
import SwiftUI

/// Re-resolves each selected source at play time. Unlocked URLs are never saved as resume identities.
@MainActor
struct CatalogSourcesView: View {
    let title: TMDBTitle
    let episode: TMDBEpisode?
    @State private var sources: [AllDebridTitleMatcher.Source] = []
    @State private var files: [AllDebridMagnetFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var request: Request?
    @State private var resumes = true
    private struct Request: Identifiable {
        let id = UUID()
        let url: URL
        let subtitles: [ExternalSubtitleTrack]
        let scope: String
    }

    private var progress: CatalogProgress? {
        CatalogProgressStore.shared.progress(title: title, episode: episode, scope: DiscoveryStore.shared.scope)
    }

    var body: some View {
        NavigationStack {
            List {
                if let progress, !progress.completed, progress.position > 0 {
                    Toggle("Resume at \(Int(progress.position / 60)) min", isOn: $resumes)
                }
                ForEach(sources) { source in
                    Button {
                        Task { await play(source) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.filename).font(.headline)
                            Text(source.details).font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(loading)
                }
                if !loading, sources.isEmpty, error == nil {
                    Text("No matching playable file is available in your AllDebrid library. No content was acquired.")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                Button("Refresh Available Files") { Task { await load() } }.disabled(loading)
            }
            .navigationTitle("Select Source")
            .overlay {
                if loading {
                    ProgressView()
                }
            }
            .task { await load() }
            .sheet(item: $request, onDismiss: { Task { await DiscoveryStore.shared.sync(force: true) } }) { request in
                CatalogPlayerView(
                    title: title,
                    episode: episode,
                    url: request.url,
                    subtitles: request.subtitles,
                    scope: request.scope,
                    resumes: resumes,
                )
            }
        }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            guard let key = try AllDebridCredentialStore().load()
            else { throw AllDebridAPIClient.APIError.invalidAPIKey }
            let snapshot = try await AllDebridAPIClient(apiKey: key).librarySnapshot()
            try Task.checkCancellation()
            files = snapshot.magnetFiles
            let names = Dictionary(
                snapshot.magnets.map { ($0.id, $0.filename) },
                uniquingKeysWith: { first, _ in first },
            )
            sources = AllDebridTitleMatcher.sources(
                title: title,
                episode: episode,
                files: files,
                links: snapshot.savedLinks,
                magnetNames: names,
            )
        } catch { self.error = error.localizedDescription }
    }

    private func play(_ source: AllDebridTitleMatcher.Source) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            guard let key = try AllDebridCredentialStore().load()
            else { throw AllDebridAPIClient.APIError.invalidAPIKey }
            let resolved = try await AllDebridAPIClient(apiKey: key).resolvePlaybackURL(
                source.link,
                filename: source.filename,
            )
            let subtitles: [ExternalSubtitleTrack] = if case let .magnet(file) = source {
                AllDebridSubtitleMatcher.externalTracks(
                    for: file,
                    in: files,
                )
            } else {
                []
            }
            request = Request(url: resolved.url, subtitles: subtitles, scope: DiscoveryStore.shared.scope)
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct CatalogPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
        @State private var viewModel: PlayerViewModel
    #else
        @State private var player: AVPlayer?
        @State private var observer: Any?
        private let url: URL
        private let resume: Double
        private let title: TMDBTitle
        private let episode: TMDBEpisode?
        private let scope: String
        @State private var tracker: TrackerPlaybackSession?
    #endif

    init(
        title: TMDBTitle,
        episode: TMDBEpisode?,
        url: URL,
        subtitles: [ExternalSubtitleTrack],
        scope: String,
        resumes: Bool,
    ) {
        let saved = CatalogProgressStore.shared.progress(title: title, episode: episode, scope: scope)
        let offset = resumes && saved?.completed != true ? saved?.position ?? 0 : 0
        #if os(iOS)
            _viewModel = State(initialValue: PlayerViewModel(
                localMedia: CatalogMediaFactory.make(title: title, episode: episode, resume: offset > 0 ? offset : nil),
                localPlaybackURL: url, localExternalSubtitles: subtitles,
                catalogTrackerItem: title.trackerItem(episode: episode),
                catalogProgress: { position, duration, finished in
                    CatalogProgressStore.shared.save(
                        title: title,
                        episode: episode,
                        position: position,
                        duration: duration,
                        finished: finished,
                        scope: scope,
                    )
                },
            ))
        #else
            self.title = title; self.episode = episode; self.url = url; self.scope = scope; resume = offset
        #endif
    }

    var body: some View {
        Group {
            #if os(iOS)
                PlayerWrapper(viewModel: viewModel)
            #else
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            #endif
        }
        .overlay(alignment: .topTrailing) {
            Button("Done", systemImage: "xmark") { dismiss() }
                .padding().background(.regularMaterial, in: Circle()).padding()
        }
        #if !os(iOS)
        .task {
            let player = AVPlayer(url: url)
            self.player = player
            if let item = title
                .trackerItem(episode: episode)
            {
                tracker = TrackerCoordinator.shared.beginCatalogPlayback(
                    item: item,
                    resumeOffset: resume,
                )
            }
            if resume > 0 {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 10, preferredTimescale: 600),
                queue: .main,
            ) { time in
                Task { @MainActor in
                    let duration = player.currentItem?.duration.seconds
                    CatalogProgressStore.shared.save(
                        title: title,
                        episode: episode,
                        position: time.seconds,
                        duration: duration,
                        finished: false,
                        scope: scope,
                    )
                    if player.rate > 0 {
                        tracker?.playing(position: time.seconds, duration: duration)
                    } else {
                        tracker?.paused(position: time.seconds, duration: duration)
                    }
                }
            }
            player.play()
        }
        .onDisappear {
            guard let player else { return }
            let position = player.currentTime().seconds
            let duration = player.currentItem?.duration.seconds
            tracker?.stopped(position: position, duration: duration)
            CatalogProgressStore.shared.save(
                title: title,
                episode: episode,
                position: position,
                duration: duration,
                finished: false,
                scope: scope,
            )
            if let observer {
                player.removeTimeObserver(observer)
            }
            player.pause(); self.player = nil
        }
        #endif
    }
}

private enum CatalogMediaFactory {
    static func make(title: TMDBTitle, episode: TMDBEpisode?, resume: Double?) -> MediaItem {
        MediaItem(
            id: CatalogProgress.key(title: title, episode: episode),
            guid: "tmdb://\(title.catalogID)",
            summary: episode?.overview ?? title.overview,
            title: episode?.name ?? title.displayTitle,
            type: episode == nil ? .movie : .episode,
            parentRatingKey: nil,
            grandparentRatingKey: nil,
            genres: [],
            year: Int(title.date.prefix(4)),
            duration: episode?.runtime.map { Double($0) * 60 },
            videoResolution: nil,
            rating: nil,
            ratings: [],
            contentRating: nil,
            studio: nil,
            tagline: nil,
            thumbPath: nil,
            artPath: nil,
            artworkCornerColors: nil,
            viewOffset: resume,
            viewCount: nil,
            childCount: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            grandparentTitle: episode == nil ? nil : title.displayTitle,
            parentTitle: nil,
            parentIndex: episode?.season_number,
            index: episode?.episode_number,
            grandparentThumbPath: nil,
            grandparentArtPath: nil,
            parentThumbPath: nil,
        )
    }
}
