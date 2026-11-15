import AetherEngine
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
                if let progress, !progress.completed, progress.locallyCleared != true,
                   progress.fraction > 0 || progress.position > 0
                {
                    Toggle(isOn: $resumes) {
                        Text("Resume playback")
                        if let remaining = RemainingTimeFormatter.text(
                            duration: progress.duration,
                            viewOffset: progress.position,
                        ) {
                            Text(remaining).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
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
                if progress != nil {
                    Button("Clear Saved Resume Position", role: .destructive) {
                        CatalogProgressStore.shared.clear(
                            title: title,
                            episode: episode,
                            scope: DiscoveryStore.shared.scope,
                        )
                        resumes = false
                    }.disabled(loading)
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
                    scope: request.scope,
                    url: request.url,
                    subtitles: request.subtitles,
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
            try Task.checkCancellation()
            if !resumes || progress?.completed == true {
                CatalogProgressStore.shared.restart(title: title, episode: episode, scope: scope)
            }
            request = Request(url: resolved.url, subtitles: subtitles, scope: scope)
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct CatalogPlayerView: View {
    let title: TMDBTitle
    let episode: TMDBEpisode?
    let scope: String
    let url: URL
    let subtitles: [ExternalSubtitleTrack]
    let resumes: Bool
    @State private var viewModel: PlayerViewModel?

    var body: some View {
        Group {
            if let viewModel {
                NativePlaybackView(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .task {
            // A SwiftUI value-view reconstruction must not start another tracking session.
            guard viewModel == nil else { return }
            let saved = CatalogProgressStore.shared.progress(title: title, episode: episode, scope: scope)
            let offset = resumes ? saved?.resumeOffset ?? 0 : 0
            viewModel = PlayerViewModel(
                localMedia: CatalogMediaAdapter.make(title: title, episode: episode, resume: offset > 0 ? offset : nil),
                localPlaybackURL: url, localExternalSubtitles: subtitles, resumes: resumes,
                catalogTrackerItem: title.trackerItem(episode: episode),
                catalogRecorder: CatalogProgressStore.shared.makeRecorder(title: title, episode: episode, scope: scope),
                catalogResumePercentage: resumes ? saved?.resumePercentage : nil,
            )
        }
        .onDisappear { CatalogProgressStore.shared.endPlayback(title: title, episode: episode, scope: scope) }
    }
}

/// Presentation adapter only: each platform renders its original Strimr player, controls and timeline.
@MainActor
struct NativePlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    @State var viewModel: PlayerViewModel
    @State private var presentationID = UUID()
    var body: some View {
        #if os(macOS)
            PlayerView(viewModel: viewModel, presentationID: presentationID, onClose: { dismiss() })
        #elseif os(tvOS)
            PlayerWrapper(viewModel: viewModel, onExit: { dismiss() })
        #else
            PlayerWrapper(viewModel: viewModel)
        #endif
    }
}
