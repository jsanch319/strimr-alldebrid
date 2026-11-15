import SwiftUI

struct ContentView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(ServerRegistry.self) private var registry
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflineCoordinator.self) private var offlineCoordinator
    @Environment(ExternalPlaybackCallbackRouter.self) private var externalPlaybackCallbackRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingAppURL: URL?
    @State private var hasAllDebridCredentials = false
    @State private var allDebridCredentialError: String?

    init() {
        ErrorReporter.start()
    }

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()

            if showsStaticDownloads {
                OfflineDownloadsRootView()
            } else {
                switch sessionManager.status {
                case .hydrating:
                    if let profile = sessionManager.activeProfile {
                        ProfileActivationView(profile: profile)
                            .transition(.profileActivation)
                    } else {
                        ProgressView(sessionManager.loadingPhase.title)
                            .progressViewStyle(.circular)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .needsAccount:
                    if hasAllDebridCredentials {
                        AllDebridOnlyHomeView {
                            refreshAllDebridCredentialState()
                        }
                    } else {
                        AccountSetupView(purpose: .firstLaunch, sessionManager: sessionManager)
                    }
                case .needsProfileSelection:
                    NavigationStack {
                        ProfileSwitcherView(viewModel: ProfileSwitcherViewModel(sessionManager: sessionManager))
                    }
                case .migrationFailed:
                    MigrationFailedView()
                case .ready:
                    MainTabView(
                        homeViewModel: HomeViewModel(sessionManager: sessionManager, settingsManager: settingsManager),
                        libraryViewModel: LibraryViewModel(
                            sessionManager: sessionManager,
                            libraryStore: libraryStore,
                            settingsManager: settingsManager,
                        ),
                        settingsManager: settingsManager,
                        pendingAppURL: $pendingAppURL,
                    )
                    .id(registry.generation)
                }
            }
        }
        .overlay(alignment: .top) {
            #if DEBUG && targetEnvironment(simulator)
                if CatalogVisualFixtures.isEnabled {
                    Text("SIMULATOR · FIXTURE DATA")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.8), in: Capsule())
                        .accessibilityIdentifier("visual.fixture-label")
                        .allowsHitTesting(false)
                }
            #endif
        }
        .onChange(of: offlineCoordinator.availability.hasNetworkPath) { _, hasNetworkPath in
            guard hasNetworkPath, sessionManager.status == .migrationFailed else { return }
            Task {
                await sessionManager.hydrate()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                offlineCoordinator.availability.refresh()
                registry.retryUnavailable()
            case .background:
                offlineCoordinator.evictCacheIfNeeded()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: settingsManager.downloads.offlineCacheLimitMB, initial: true) { _, megabytes in
            offlineCoordinator.setCacheLimit(megabytes: megabytes)
        }
        .onChange(of: registry.connectedServices.map(ObjectIdentifier.init), initial: true) { _, _ in
            downloadManager.activateSession(services: registry.connectedServices)
        }
        .task {
            refreshAllDebridCredentialState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .allDebridCredentialsDidChange)) { _ in
            refreshAllDebridCredentialState()
        }
        .alert(
            "AllDebrid",
            isPresented: Binding(
                get: { allDebridCredentialError != nil },
                set: {
                    if !$0 {
                        allDebridCredentialError = nil
                    }
                },
            ),
        ) {
            Button("OK", role: .cancel) { allDebridCredentialError = nil }
        } message: {
            Text(allDebridCredentialError ?? "Unable to read AllDebrid credentials.")
        }
        .onOpenURL { url in
            guard !externalPlaybackCallbackRouter.receive(url), url.scheme?.lowercased() == "strimr" else { return }
            pendingAppURL = url
        }
    }

    /// Without a restorable session and without network, downloads are shown directly at launch.
    private var showsStaticDownloads: Bool {
        guard !offlineCoordinator.availability.hasNetworkPath, downloadManager.playableCount > 0 else { return false }
        switch sessionManager.status {
        case .needsAccount, .migrationFailed:
            return true
        case .hydrating, .needsProfileSelection, .ready:
            return false
        }
    }

    private func refreshAllDebridCredentialState() {
        #if DEBUG && targetEnvironment(simulator)
            if CatalogVisualFixtures.isEnabled {
                hasAllDebridCredentials = true
                allDebridCredentialError = nil
                return
            }
        #endif
        do {
            hasAllDebridCredentials = try AllDebridCredentialStore().load() != nil
            allDebridCredentialError = nil
        } catch {
            hasAllDebridCredentials = false
            allDebridCredentialError = error.localizedDescription
        }
    }
}
