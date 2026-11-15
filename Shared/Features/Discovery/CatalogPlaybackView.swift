import AetherEngine
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
                if let progress, !progress.completed, progress.fraction > 0 || progress.position > 0 {
                    Toggle("Resume at \(Int(progress.fraction * 100))%", isOn: $resumes)
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
                if let warning = DiscoveryStore.shared
                    .errorMessage
                {
                    Text(warning).font(.footnote).foregroundStyle(.secondary)
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
            await DiscoveryStore.shared.sync(force: true)
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
        let scope = DiscoveryStore.shared.scope
        do {
            await DiscoveryStore.shared.sync(force: true)
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
            guard DiscoveryStore.shared.scope == scope else { throw TrackerAPIError.unavailable }
            request = Request(url: resolved.url, subtitles: subtitles, scope: scope)
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
        @State private var statusObservation: NSKeyValueObservation?
        @State private var durationObservation: NSKeyValueObservation?
        private let remotePercentage: Double?
        #if !os(tvOS)
            private let recorder: PlaybackProgressRecorder
        #endif
        private let url: URL
        private let resume: Double
        @State private var tracker: TrackerPlaybackSession?
    #endif

    private let title: TMDBTitle
    private let episode: TMDBEpisode?
    private let scope: String

    init(
        title: TMDBTitle,
        episode: TMDBEpisode?,
        url: URL,
        subtitles: [ExternalSubtitleTrack],
        scope: String,
        resumes: Bool,
    ) {
        self.title = title; self.episode = episode; self.scope = scope
        let saved = CatalogProgressStore.shared.progress(title: title, episode: episode, scope: scope)
        let offset = resumes && saved?.completed != true ? saved?.position ?? 0 : 0
        let remotePercentage = resumes && saved?.completed != true && saved?.pendingSync == false ? saved?
            .remotePercentage : nil
        #if os(iOS)
            _viewModel = State(initialValue: PlayerViewModel(
                localMedia: CatalogMediaFactory.make(title: title, episode: episode, resume: offset > 0 ? offset : nil),
                localPlaybackURL: url, localExternalSubtitles: subtitles,
                resumes: resumes,
                catalogTrackerItem: title.trackerItem(episode: episode),
                catalogRecorder: CatalogProgressStore.shared.makeRecorder(title: title, episode: episode, scope: scope),
                catalogResumePercentage: remotePercentage,
            ))
        #else
            self.url = url; resume = offset
            self.remotePercentage = remotePercentage
            #if !os(tvOS)
                recorder = CatalogProgressStore.shared.makeRecorder(title: title, episode: episode, scope: scope)
            #endif
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
        .onDisappear { CatalogProgressStore.shared.endPlayback(title: title, episode: episode, scope: scope) }
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
                durationObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { item, _ in
                    Task { @MainActor in
                        guard item.status == .readyToPlay else { return }
                        let target = remotePercentage.flatMap { PlaybackProgressConflict.position(
                            percentage: $0,
                            duration: item.duration.seconds,
                        ) } ?? resume
                        tracker?.updateInitialResumeOffset(target)
                        if target > 0 {
                            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                        }
                        player.play()
                    }
                }
                statusObservation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
                    Task { @MainActor in
                        let position = player.currentTime().seconds
                        let duration = player.currentItem?.duration.seconds
                        switch player.timeControlStatus {
                        case .playing: tracker?.playing(position: position, duration: duration)
                        case .paused:
                            #if !os(tvOS)
                                recorder.record(position: position, duration: duration, isPaused: true)
                            #else
                                CatalogProgressStore.shared.save(
                                    title: title,
                                    episode: episode,
                                    position: position,
                                    duration: duration,
                                    finished: false,
                                    scope: scope,
                                    event: "pause",
                                )
                            #endif
                            tracker?.paused(position: position, duration: duration)
                        default: break
                        }
                    }
                }
                observer = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 10, preferredTimescale: 600),
                    queue: .main,
                ) { time in
                    Task { @MainActor in
                        let duration = player.currentItem?.duration.seconds
                        #if !os(tvOS)
                            recorder.record(position: time.seconds, duration: duration, isPaused: player.rate == 0)
                        #else
                            CatalogProgressStore.shared.save(
                                title: title,
                                episode: episode,
                                position: time.seconds,
                                duration: duration,
                                finished: false,
                                scope: scope,
                                event: "progress",
                            )
                        #endif
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
                #if !os(tvOS)
                    recorder.finish(pushesImmediately: false)
                #else
                    CatalogProgressStore.shared.save(
                        title: title,
                        episode: episode,
                        position: item.duration.seconds,
                        duration: item.duration.seconds,
                        finished: true,
                        scope: scope,
                        event: "watched",
                    )
                #endif
                tracker?.finished()
            }
            .onDisappear {
                guard let player else { return }
                let position = player.currentTime().seconds
                let duration = player.currentItem?.duration.seconds
                #if !os(tvOS)
                    recorder.stop(position: position)
                #else
                    CatalogProgressStore.shared.save(
                        title: title,
                        episode: episode,
                        position: position,
                        duration: duration,
                        finished: false,
                        scope: scope,
                    )
                #endif
                tracker?.stopped(position: position, duration: duration)
                CatalogProgressStore.shared.endPlayback(title: title, episode: episode, scope: scope)
                statusObservation?.invalidate(); durationObservation?.invalidate()
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
