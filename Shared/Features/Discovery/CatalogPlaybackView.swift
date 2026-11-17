import AetherEngine
import SwiftUI

/// Playback entry for both Auto Play and the explicit manual selector. Uses the original native player.
@MainActor
struct CatalogSourcesView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss
    let title: TMDBTitle
    let episode: TMDBEpisode?
    var forceManual = false
    @State private var resolver: CatalogSourceResolver?
    @State private var loading = false
    @State private var error: String?
    @State private var request: Request?
    @State private var resumes = true
    @State private var automatic = true
    @State private var pendingFailure: String?
    @State private var restartApplied = false
    @State private var initialized = false
    @State private var sourceScope: String?
    init(title: TMDBTitle, episode: TMDBEpisode?, startsFromBeginning: Bool = false, forceManual: Bool = false) {
        self.title = title; self.episode = episode; self.forceManual = forceManual
        _resumes = State(initialValue: !startsFromBeginning)
        _automatic = State(initialValue: !forceManual)
    }

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
            Group {
                if automatic {
                    VStack(spacing: 20) {
                        if loading || request != nil || !initialized {
                            ProgressView("Opening playback…")
                        }
                        if let error {
                            Text(error).multilineTextAlignment(.center)
                            Button("Refresh and Retry") { Task { await load() } }.disabled(loading)
                            if resolver?.sources.isEmpty == false {
                                Button("Select Source") { automatic = false; self.error = nil }
                            }
                        }
                    }.padding()
                } else {
                    List {
                        if let progress, !progress.completed, progress.locallyCleared != true,
                           progress.fraction > 0 || progress.position > 0
                        {
                            Toggle("Resume playback", isOn: $resumes)
                        }
                        ForEach(resolver?.sources ?? []) { source in
                            Button { Task { await play(source) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(source.filename).font(.headline)
                                    Text(source.details).font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(loading)
                        }
                        if let error {
                            Text(error).foregroundStyle(.secondary)
                        }
                        ForEach(resolver?.warnings ?? [], id: \.self) { Text($0).font(.footnote) }
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
                    .overlay {
                        if loading {
                            ProgressView()
                        }
                    }
                }
            }
            .navigationTitle(automatic ? "Play" : "Select Source")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                guard !initialized else { return }
                initialized = true
                automatic = !forceManual && settingsManager.playback.allDebridAutoPlay
                await load()
            }
            .onReceive(NotificationCenter.default.publisher(for: .allDebridCredentialsDidChange)) { _ in
                sourceScope = nil
                resolver = nil
                pendingFailure = nil
                request = nil
                error = "The AllDebrid connection changed. Refresh available files to use the current account."
            }
            .sheet(item: $request, onDismiss: playerDismissed) { request in
                CatalogPlayerView(
                    title: title,
                    episode: episode,
                    scope: request.scope,
                    url: request.url,
                    subtitles: request.subtitles,
                    resumes: resumes,
                    onFailure: automatic ? { message in
                        pendingFailure = message
                        self.request = nil
                    } : nil,
                )
            }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        let scope = DiscoveryStore.shared.scope
        do {
            guard let key = try AllDebridCredentialStore().load()
            else { throw AllDebridAPIClient.APIError.invalidAPIKey }
            let client = try AllDebridAPIClient(apiKey: key)
            let next = CatalogSourceResolver(client: client)
            sourceScope = scope
            resolver = next // A refresh never retains stale files or a previous authentication failure.
            async let resumeSync: Void = DiscoveryStore.shared.sync(force: true)
            var metadata = title
            do { metadata = try await TMDBClient.shared.details(title) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Cached title identity remains usable if TMDb is temporarily unavailable. */ }
            try await next.refresh(title: metadata, episode: episode)
            await resumeSync
            guard sourceScope == scope, scope == DiscoveryStore.shared.scope else { throw TrackerAPIError.unavailable }
            if automatic {
                try await open(next.resolveNext(), scope: scope)
            }
        } catch {
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }

    private func play(_ source: AllDebridTitleMatcher.Source) async {
        guard !loading, let resolver else { return }
        loading = true; error = nil
        defer { loading = false }
        let scope = DiscoveryStore.shared.scope
        guard sourceScope == scope else {
            error = "The account changed. Refresh available files before playing."
            return
        }
        do { try await open(resolver.resolveSelected(source), scope: scope) }
        catch {
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }

    private func open(_ resolved: CatalogSourceResolver.Resolved, scope: String) async throws {
        try Task.checkCancellation()
        guard sourceScope == scope, scope == DiscoveryStore.shared.scope else { throw TrackerAPIError.unavailable }
        // Fence old remote progress only once, after a source actually resolves. Fallback keeps new checkpoints.
        if !restartApplied, !resumes || progress?.completed == true {
            CatalogProgressStore.shared.restart(title: title, episode: episode, scope: scope)
            restartApplied = true
        }
        request = Request(url: resolved.url, subtitles: resolved.subtitles, scope: scope)
    }

    private func playerDismissed() {
        if pendingFailure != nil, automatic {
            pendingFailure = nil
            resumes = true
            Task {
                loading = true
                defer { loading = false }
                do {
                    guard let resolver else { return }
                    let scope = DiscoveryStore.shared.scope
                    try await open(resolver.resolveNext(), scope: scope)
                } catch {
                    if !error.isCancellation {
                        self.error = error.localizedDescription
                    }
                }
            }
        } else {
            Task { await DiscoveryStore.shared.sync(force: true) }
            if automatic {
                dismiss()
            }
        }
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
    var onFailure: ((String) -> Void)?
    @State private var failureReported = false
    @State private var viewModel: PlayerViewModel?

    var body: some View {
        Group {
            if let viewModel {
                NativePlaybackView(viewModel: viewModel, onFailure: onFailure.map { callback in
                    { message in
                        guard !failureReported else { return }
                        failureReported = true
                        callback(message)
                    }
                })
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
    var onFailure: ((String) -> Void)?
    @State private var presentationID = UUID()
    var body: some View {
        #if os(macOS)
            PlayerView(viewModel: viewModel, presentationID: presentationID, onClose: { dismiss() })
        #elseif os(tvOS)
            PlayerWrapper(viewModel: viewModel, onExit: { dismiss() })
        #else
            PlayerWrapper(viewModel: viewModel, onPlaybackFailure: onFailure)
        #endif
    }
}
