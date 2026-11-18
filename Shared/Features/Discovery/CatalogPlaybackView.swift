import AetherEngine
import SwiftUI

/// Availability is checked before either Auto Play or manual selection; playback stays in the original player.
@MainActor
struct CatalogSourcesView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(SharePlayCoordinator.self) private var sharePlayCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let title: TMDBTitle
    let episode: TMDBEpisode?
    var forceManual = false
    @State private var resolver: CatalogSourceResolver?
    @State private var loading = false
    @State private var error: String?
    @State private var request: Request?
    @State private var englishReplacement: Request?
    @State private var triedEnglishReplacement = false
    @State private var englishAudioContext = EnglishAudioPlaybackContext()
    @State private var resumes = true
    @State private var automatic = true
    @State private var pendingFailure: String?
    @State private var restartApplied = false
    @State private var initialized = false
    @State private var sourceScope: String?
    @State private var metadata: TMDBTitle?
    @State private var canPoll = false
    @State private var operation = Operation.refresh
    @State private var operationID = UUID()
    @AppStorage(AuthorizedSourceSettings.key) private var sourceEndpoints = ""
    @State private var showingLinkEntry = false
    @State private var authorizedLink = ""
    @State private var confirmsAuthorization = false

    init(title: TMDBTitle, episode: TMDBEpisode?, startsFromBeginning: Bool = false, forceManual: Bool = false) {
        self.title = title; self.episode = episode; self.forceManual = forceManual
        _resumes = State(initialValue: !startsFromBeginning)
        _automatic = State(initialValue: !forceManual)
    }

    private enum Operation: Equatable { case refresh, selected(AllDebridTitleMatcher.Source), fallback,
                                             importLink(String), englishReplacement
    }

    private struct OperationKey: Equatable { let id: UUID; let active: Bool; let scope: String }
    private struct PollKey: Equatable { let enabled: Bool; let active: Bool; let scope: String; let operation: UUID }
    private struct Request: Identifiable {
        let id = UUID()
        let url: URL
        let subtitles: [ExternalSubtitleTrack]
        let scope: String
        var exactResume: Double?
    }

    private var isSharedPlayback: Bool {
        sharePlayCoordinator.isInSession && sharePlayCoordinator.activity?.catalog != nil &&
            sharePlayCoordinator.activity?.ratingKey == CatalogProgress.key(title: title, episode: episode)
    }

    private var progress: CatalogProgress? {
        CatalogProgressStore.shared.progress(title: title, episode: episode, scope: DiscoveryStore.shared.scope)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !automatic, resolver?.sources.isEmpty == false {
                    List {
                        if !isSharedPlayback, let progress, !progress.completed, progress.locallyCleared != true,
                           progress.fraction > 0 || progress.position > 0
                        {
                            Toggle("Resume playback", isOn: $resumes)
                        }
                        ForEach(resolver?.sources ?? []) { source in
                            Button { schedule(.selected(source)) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(source.filename).font(.headline)
                                    Text(source.details).font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(loading || !source.isSupported)
                        }
                        if let error {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(resolver?.warnings ?? [], id: \.self) { Text($0).font(.footnote) }
                        if !isSharedPlayback, progress != nil {
                            Button("Clear Saved Resume Position", role: .destructive) {
                                CatalogProgressStore.shared.clear(
                                    title: title,
                                    episode: episode,
                                    scope: DiscoveryStore.shared.scope,
                                )
                                resumes = false
                            }.disabled(loading)
                        }
                        Button("Refresh Available Files") { schedule(.refresh) }.disabled(loading)
                    }
                    .overlay {
                        if loading {
                            ProgressView()
                        }
                    }
                } else {
                    ScrollView { availabilityStatus }
                }
            }
            .navigationTitle(automatic ? "Play" : "Select Source")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .task(id: OperationKey(
                    id: operationID,
                    active: scenePhase == .active,
                    scope: DiscoveryStore.shared.scope,
                )) {
                    guard scenePhase == .active, request == nil else { return }
                    if !initialized {
                        initialized = true
                        automatic = !forceManual && settingsManager.playback.allDebridAutoPlay
                    }
                    let id = operationID
                    let work = operation
                    defer {
                        if id == operationID, !Task.isCancelled {
                            operation = .refresh
                        }
                    }
                    switch work {
                    case .refresh: await load()
                    case let .selected(source): await play(source)
                    case .fallback: await playNext()
                    case let .importLink(link): await importLink(link)
                    case .englishReplacement:
                        if let next = englishReplacement, next.scope == DiscoveryStore.shared.scope,
                           settingsManager.playback.alwaysPreferEnglishAudio
                        {
                            resumes = true; englishReplacement = nil; request = next
                        } else {
                            englishReplacement = nil
                        }
                    }
                }
                .task(id: PollKey(
                    enabled: canPoll,
                    active: scenePhase == .active,
                    scope: DiscoveryStore.shared.scope,
                    operation: operationID,
                )) {
                    await pollAvailability()
                }
                .onChange(of: sourceEndpoints) { _, _ in
                    resolver = nil; canPoll = false; sourceScope = nil; loading = false; schedule(.refresh)
                }
                .onReceive(NotificationCenter.default.publisher(for: .stremioAddonsDidChange)) { _ in
                    canPoll = false; sourceScope = nil; resolver = nil; loading = false
                    schedule(.refresh)
                }
                .onReceive(NotificationCenter.default.publisher(for: .allDebridCredentialsDidChange)) { _ in
                    canPoll = false; sourceScope = nil; resolver = nil; metadata = nil
                    pendingFailure = nil; request = nil; loading = false
                    englishReplacement = nil; triedEnglishReplacement = false; englishAudioContext.manualTrack = nil
                    error = "The AllDebrid connection changed. Checking the current account…"
                    schedule(.refresh)
                }
                .sheet(isPresented: $showingLinkEntry) {
                    NavigationStack {
                        Form {
                            Section("Authorized magnet or download link") {
                                TextField("Paste link", text: $authorizedLink).autocorrectionDisabled()
                                Toggle("I have permission to access this content", isOn: $confirmsAuthorization)
                                Text("The actual file must match this title, year and episode before it can play.")
                                    .font(.footnote)
                                Button("Add and Check Availability") {
                                    let link = authorizedLink.trimmingCharacters(in: .whitespacesAndNewlines)
                                    showingLinkEntry = false; authorizedLink = ""; confirmsAuthorization = false
                                    schedule(.importLink(link))
                                }
                                .disabled(!confirmsAuthorization || !AuthorizedSourceCandidate
                                    .validLink(authorizedLink.trimmingCharacters(in: .whitespacesAndNewlines)))
                            }
                        }
                        .navigationTitle("Add Authorized Link")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showingLinkEntry = false; authorizedLink = "" }
                            }
                        }
                    }
                }
                .sheet(item: $request, onDismiss: playerDismissed) { request in
                    CatalogPlayerView(
                        title: title,
                        episode: episode,
                        scope: request.scope,
                        url: request.url,
                        subtitles: request.subtitles,
                        resumes: resumes,
                        exactResume: request.exactResume,
                        englishAudioFallback: EnglishAudioFallback(
                            context: englishAudioContext,
                            find: {
                                guard automatic, !triedEnglishReplacement,
                                      settingsManager.playback.alwaysPreferEnglishAudio,
                                      scenePhase == .active, sourceScope == request.scope, progress?.completed != true,
                                      let resolver else { return nil }
                                triedEnglishReplacement = true
                                return try? await resolver.englishAudioAlternative()
                            },
                            activate: { result, seconds in
                                guard scenePhase == .active, self.request?.id == request.id,
                                      sourceScope == request.scope, request.scope == DiscoveryStore.shared.scope,
                                      progress?.completed != true,
                                      settingsManager.playback.alwaysPreferEnglishAudio,
                                      resolver?.acceptEnglishAudioAlternative(result) == true else { return }
                                englishReplacement = Request(
                                    url: result.url,
                                    subtitles: result.subtitles,
                                    scope: request.scope,
                                    exactResume: seconds,
                                )
                                self.request = nil
                            },
                            chooseSource: {
                                automatic = false; resumes = true; pendingFailure = nil
                                self.request = nil
                            },
                        ),
                        onFailure: automatic ?
                            { message in pendingFailure = message; self.request = nil } : nil,
                    )
                }
        }
        #if os(iOS)
        .presentationDetents(!automatic && resolver?.sources.isEmpty == false ? [.medium, .large] : [
            .height(300),
            .medium,
        ])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var availabilityStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if loading || request != nil || !initialized || resolver?.availability == .processing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "film.stack").foregroundStyle(.secondary)
                }
                Text(statusTitle).font(.headline)
            }
            Text(title.displayTitle + (episode.map { " · S\($0.season_number) E\($0.episode_number)" } ?? ""))
                .font(.subheadline).lineLimit(1)
            if let pending = resolver?.processingMagnets.first {
                Text(pending.filename + " · " + pending.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 16) {
                Button("Retry", systemImage: "arrow.clockwise") { schedule(.refresh) }.disabled(loading)
                if resolver?.sources.isEmpty == false {
                    Button("Select Source") { automatic = false; error = nil; canPoll = false; schedule(.refresh) }
                }
            }
            if resolver?.availability == .missing || resolver?.availability == .incomplete {
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink("Stremio Add-ons") { StremioAddonsView() }
                    NavigationLink(resolver?.needsSourceSetup == true ? "Set Up Sources" : "Manage Sources") {
                        AuthorizedSourceSetupView()
                    }
                    Button("Add Authorized Link") { showingLinkEntry = true }.disabled(loading || resolver == nil)
                }.font(.subheadline)
            }
            if canPoll {
                Text("Availability refreshes automatically while this screen is open.").font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("catalog.availability")
    }

    private var statusTitle: String {
        if loading || !initialized {
            return "Checking AllDebrid…"
        }
        if request != nil {
            return "Opening playback…"
        }
        switch resolver?.availability {
        case .processing: return "Processing in AllDebrid"
        case .missing: return "Not in your AllDebrid library"
        case .incomplete: return "Library check incomplete"
        default: return "Playback unavailable"
        }
    }

    private func schedule(_ work: Operation) {
        operation = work; operationID = UUID()
    }

    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        let id = operationID
        defer {
            if id == operationID {
                loading = false
            }
        }
        let scope = DiscoveryStore.shared.scope
        do {
            let next: CatalogSourceResolver
            if let resolver, sourceScope == scope {
                next = resolver
            } else {
                guard let key = try AllDebridCredentialStore().load()
                else { throw AllDebridAPIClient.APIError.invalidAPIKey }
                let client = try AllDebridAPIClient(apiKey: key)
                let acquisition = CatalogSourceAcquisition(
                    client: client,
                    providers: AuthorizedSourceSettings
                        .providers(UserDefaults.standard
                            .string(forKey: AuthorizedSourceSettings.key) ?? ""),
                    account: key,
                )
                next = CatalogSourceResolver(
                    client: client,
                    acquisition: acquisition,
                    stremio: StremioPlaybackSources(),
                )
                resolver = next; sourceScope = scope; metadata = nil
            }
            if metadata == nil {
                do { metadata = try await TMDBClient.shared.details(title) }
                catch is CancellationError { throw CancellationError() }
                catch { metadata = title }
            }
            try await next.refresh(
                title: metadata ?? title,
                episode: episode,
                includeAddons: !automatic,
                preferEnglish: settingsManager.playback.alwaysPreferEnglishAudio,
            )
            try Task.checkCancellation()
            guard id == operationID, sourceScope == scope, scope == DiscoveryStore.shared.scope else { return }
            if automatic {
                await DiscoveryStore.shared.sync(force: true)
                try Task.checkCancellation()
                guard scenePhase == .active else { canPoll = true; return }
                try await open(next.resolveNext(), scope: scope)
            }
            canPoll = false
        } catch {
            guard !error.isCancellation, id == operationID, sourceScope == scope || sourceScope == nil else { return }
            self.error = error.localizedDescription
            canPoll = !AllDebridAPIClient.isAuthenticationOrRateLimit(error)
                && !(error is StremioError)
                && [.processing, .missing, .incomplete].contains(resolver?.availability ?? .checking)
        }
    }

    private func importLink(_ link: String) async {
        guard !loading, let resolver, sourceScope == DiscoveryStore.shared.scope else { return }
        loading = true; canPoll = false; error = nil
        do {
            try await resolver.addAuthorizedLink(link, title: metadata ?? title, episode: episode)
            try Task.checkCancellation()
            loading = false
            schedule(.refresh)
        } catch {
            loading = false
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }

    private func pollAvailability() async {
        guard canPoll, scenePhase == .active else { return }
        var attempt = 0
        while canPoll, scenePhase == .active, request == nil, !Task.isCancelled {
            do { try await Task.sleep(for: CatalogAvailabilityPolling.delay(
                processing: resolver?.availability == .processing,
                attempt: attempt,
            )) } catch { return }
            guard !Task.isCancelled, scenePhase == .active, request == nil else { return }
            if !loading {
                await load()
            }
            attempt += 1
        }
    }

    private func play(_ source: AllDebridTitleMatcher.Source) async {
        guard !loading, let resolver else { return }
        loading = true; error = nil; canPoll = false
        defer { loading = false }
        let scope = DiscoveryStore.shared.scope
        guard sourceScope == scope
        else { error = "The account changed. Refresh available files before playing."; return }
        do {
            await DiscoveryStore.shared.sync(force: true)
            try Task.checkCancellation()
            guard sourceScope == scope, scope == DiscoveryStore.shared.scope else { return }
            try await open(resolver.resolveSelected(source), scope: scope)
        } catch {
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }

    private func playNext() async {
        guard !loading, let resolver else { return }
        loading = true; canPoll = false
        defer { loading = false }
        let scope = DiscoveryStore.shared.scope
        guard sourceScope == scope else { error = "The account changed. Refresh availability."; return }
        do {
            await DiscoveryStore.shared.sync(force: true)
            try Task.checkCancellation()
            guard sourceScope == scope, scope == DiscoveryStore.shared.scope else { return }
            try await open(resolver.resolveNext(), scope: scope)
        } catch {
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }

    private func open(_ resolved: CatalogSourceResolver.Resolved, scope: String) async throws {
        try Task.checkCancellation()
        guard sourceScope == scope, scope == DiscoveryStore.shared.scope else { throw TrackerAPIError.unavailable }
        if !restartApplied, !resumes || progress?.completed == true {
            CatalogProgressStore.shared.restart(title: title, episode: episode, scope: scope)
            restartApplied = true
        }
        request = Request(url: resolved.url, subtitles: resolved.subtitles, scope: scope)
    }

    private func playerDismissed() {
        if !automatic {
            Task { await DiscoveryStore.shared.sync(force: true) }
            schedule(.refresh); return
        }
        if englishReplacement != nil {
            pendingFailure = nil; schedule(.englishReplacement); return
        }
        if pendingFailure != nil, automatic {
            pendingFailure = nil; resumes = true; schedule(.fallback)
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
    @Environment(SharePlayCoordinator.self) private var sharePlayCoordinator
    let title: TMDBTitle
    let episode: TMDBEpisode?
    let scope: String
    let url: URL
    let subtitles: [ExternalSubtitleTrack]
    let resumes: Bool
    var exactResume: Double?
    var englishAudioFallback: EnglishAudioFallback?
    var onFailure: ((String) -> Void)?
    @State private var failureReported = false
    @State private var viewModel: PlayerViewModel?

    var body: some View {
        Group {
            if let viewModel {
                NativePlaybackView(
                    viewModel: viewModel,
                    englishAudioFallback: englishAudioFallback,
                    onRestartFromBeginning: {
                        CatalogProgressStore.shared.restart(title: title, episode: episode, scope: scope)
                    },
                    onFailure: onFailure.map { callback in
                        { message in
                            guard !failureReported else { return }
                            failureReported = true
                            callback(message)
                        }
                    },
                )
            } else {
                ProgressView()
            }
        }
        .task {
            // A SwiftUI value-view reconstruction must not start another tracking session.
            guard viewModel == nil else { return }
            let saved = CatalogProgressStore.shared.progress(title: title, episode: episode, scope: scope)
            let shared = sharePlayCoordinator.isInSession
                && sharePlayCoordinator.activity?.ratingKey == CatalogProgress.key(title: title, episode: episode)
                ? sharePlayCoordinator.activity?.initialPosition : nil
            let offset = shared ?? (resumes ? exactResume ?? saved?.resumeOffset ?? 0 : 0)
            viewModel = PlayerViewModel(
                localMedia: CatalogMediaAdapter.make(title: title, episode: episode, resume: offset > 0 ? offset : nil),
                localPlaybackURL: url, localExternalSubtitles: subtitles, resumes: shared != nil || resumes,
                catalogTrackerItem: title.trackerItem(episode: episode),
                catalogRecorder: CatalogProgressStore.shared.makeRecorder(title: title, episode: episode, scope: scope),
                catalogResumePercentage: shared == nil && resumes && exactResume == nil ? saved?.resumePercentage : nil,
                coordinatedResumePosition: shared,
            )
        }
        .onDisappear { CatalogProgressStore.shared.endPlayback(title: title, episode: episode, scope: scope) }
        #if os(iOS)
            .interactiveDismissDisabled(sharePlayCoordinator.isInSession)
        #endif
    }
}

/// Presentation adapter only: each platform renders its original Strimr player, controls and timeline.
@MainActor
struct NativePlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    @State var viewModel: PlayerViewModel
    var englishAudioFallback: EnglishAudioFallback?
    var onRestartFromBeginning: (() -> Void)?
    var onFailure: ((String) -> Void)?
    @State private var presentationID = UUID()
    var body: some View {
        #if os(macOS)
            PlayerView(viewModel: viewModel, presentationID: presentationID, onClose: { dismiss() })
        #elseif os(tvOS)
            PlayerWrapper(viewModel: viewModel, onExit: { dismiss() })
        #else
            PlayerWrapper(
                viewModel: viewModel,
                onPlaybackFailure: onFailure,
                englishAudioFallback: englishAudioFallback,
                onRestartFromBeginning: onRestartFromBeginning,
            )
        #endif
    }
}
