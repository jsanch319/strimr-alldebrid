import SwiftUI

@MainActor
struct HomeView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(SeerrStore.self) private var seerrStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isCatalogNavigation) private var isCatalogNavigation
    @Environment(\.mediaCardActions) private var mediaCardActions
    @State var viewModel: HomeViewModel
    @State private var selectedSheet: HomeSheet?
    @State private var hasAllDebridAccount = false
    @State private var scrollInteractionCount = 0
    @State private var featuredBackdropID: MediaIdentity?
    @State private var backdropSelection = CatalogBackdropSelection()
    @State private var heroBackdropVisible = true
    @State private var catalogSelection: CatalogHomeData.Selection?
    let onSelectMedia: (MediaDisplayItem) -> Void

    private enum HomeSheet: Identifiable {
        case hub(Hub)
        case allDebrid(AllDebridHomeItem)
        case catalogSources(CatalogHomeData.Selection)
        case catalogHub(Hub)
        case tmdbSettings
        case catalogSearch

        var id: String {
            switch self {
            case let .hub(hub): "hub:\(hub.id)"
            case let .allDebrid(item): "alldebrid:\(item.id)"
            case let .catalogSources(item): "sources:\(item.id)"
            case let .catalogHub(hub): "catalog-hub:\(hub.id)"
            case .tmdbSettings: "tmdb-settings"
            case .catalogSearch: "catalog-search"
            }
        }
    }

    init(
        viewModel: HomeViewModel,
        onSelectMedia: @escaping (MediaDisplayItem) -> Void = { _ in },
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onSelectMedia = onSelectMedia
    }

    var body: some View {
        ScrollView {
            if !viewModel.heroSlides.isEmpty {
                HomeHeroCarousel(
                    slides: viewModel.heroSlides,
                    interactionCount: scrollInteractionCount,
                    onPlay: { play($0) },
                    onDetails: { select(.playable($0)) },
                    onFeaturedChange: { media in
                        featuredBackdropID = media?.identity
                        backdropSelection.clearTapPriority()
                    },
                    onVisibilityChange: { heroBackdropVisible = $0 },
                )
            }

            VStack(alignment: .leading, spacing: 24) {
                if !viewModel.isServerFree {
                    AllDebridHomeSection(
                        onSelect: { selectedSheet = .allDebrid($0) },
                        onAccountAvailabilityChange: { hasAllDebridAccount = $0 },
                    )
                }

                ForEach(viewModel.rows) { row in
                    HomeRowSectionView(
                        row: row,
                        showsLabels: settingsManager.interface.showsCardLabels,
                        canOpenWithoutServer: viewModel.isServerFree,
                        onViewAll: { hub in
                            if viewModel
                                .isServerFree
                            {
                                selectedSheet = hub.id == "catalog:recent" ? .allDebrid(.library) : .catalogHub(hub)
                            } else {
                                selectedSheet = .hub(hub)
                            }
                        },
                        onSelectMedia: select,
                    )
                }

                if viewModel.isServerFree {
                    StreamingServicesSection()
                }

                if viewModel.isLoading, !viewModel.hasContent {
                    RailsSkeleton(showsLabels: settingsManager.interface.showsCardLabels)
                }

                if let errorMessage = viewModel.catalog?.errorMessage ?? viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if let syncError = viewModel.isServerFree ? DiscoveryStore.shared.errorMessage : nil {
                    Text(syncError).font(.footnote).foregroundStyle(.textSecondary)
                } else if !viewModel.hasContent, !hasAllDebridAccount, !viewModel.isLoading {
                    Text("common.empty.nothingToShow")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, LayoutMetrics.pageMargin)
            .padding(.vertical, 20)
        }
        .catalogBackdrop(
            media: backdropMedia,
            selection: backdropSelection,
            preferDefault: heroBackdropVisible && !viewModel.heroSlides.isEmpty,
            enabled: viewModel.isServerFree,
        )
        .onScrollPhaseChange { _, phase in
            if phase != .idle {
                scrollInteractionCount += 1
            }
        }
        #if os(iOS)
        // The hero artwork runs up behind the status and navigation bars.
        .ignoresSafeArea(edges: viewModel.heroSlides.isEmpty ? [] : .top)
        .softTopScrollEdge()
        #endif
        .navigationTitle("tabs.home")
        .tabRootChrome()
        .navigationDestination(item: $catalogSelection) { selection in
            TMDBDetailView(
                title: selection.title,
                initialSeason: selection.episode?.season_number,
                initialEpisode: selection.episode,
            )
        }
        .toolbar {
            if viewModel.isServerFree {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !isCatalogNavigation {
                        Button("tabs.search", systemImage: "magnifyingglass") { selectedSheet = .catalogSearch }
                    }
                    Menu {
                        NavigationLink("Simkl Account") { TrackerSettingsView(service: .simkl) }
                        Button("Sync Simkl") { Task { await DiscoveryStore.shared.sync(force: true) } }
                        Button("TMDb Settings") { selectedSheet = .tmdbSettings }
                        Button("AllDebrid Library") { selectedSheet = .allDebrid(.library) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Home accounts")
                }
            }
        }
        .environment(\.mediaCardActions, effectiveActions)
        .environment(\.reloadAfterPlaylistChange) { server in
            Task { await viewModel.refresh(server: server) }
        }
        .task {
            await viewModel.load()
        }
        .task(id: viewModel.isServerFree ? DiscoveryStore.shared.accountKey : "server") {
            guard viewModel.isServerFree else { return }
            await DiscoveryStore.shared.sync()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await viewModel.refreshPeriodically()
        }
        .task(id: seerrStore.isLoggedIn) {
            viewModel.seerrBaseURL = seerrStore.isLoggedIn ? seerrStore.baseURLString.flatMap(URL.init(string:)) : nil
        }
        .onChange(of: settingsManager.interface.homeHero) {
            viewModel.heroSettingsChanged()
        }
        .onChange(of: settingsManager.interface.homeHeroIncludesTrending) {
            viewModel.heroSettingsChanged()
        }
        .onAppear {
            Task { await viewModel.refreshIfNeeded() }
        }
        .refreshable {
            await viewModel.reload()
        }
        .sheet(item: $selectedSheet) { sheet in
            switch sheet {
            case let .catalogSources(selection):
                CatalogSourcesView(title: selection.title, episode: selection.episode)
            case .catalogSearch:
                if let catalog = viewModel.catalog {
                    NavigationStack { CatalogSearchView(
                        data: catalog,
                        onSelect: { media in selectedSheet = nil; select(media) },
                    ) }
                }
            case .tmdbSettings:
                TMDBSettingsView { Task { await viewModel.reload() } }
            case let .catalogHub(hub):
                NavigationStack { CatalogHubView(hub: hub, onSelect: { media in selectedSheet = nil; select(media) }) }
            case let .hub(hub):
                NavigationStack {
                    ServerScopedView(server: hub.server) { services in
                        HubDetailView(
                            viewModel: HubDetailViewModel(hub: hub, services: services),
                            onSelectMedia: { media in
                                selectedSheet = nil
                                onSelectMedia(media)
                            },
                        )
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("hub.close") {
                                selectedSheet = nil
                            }
                        }
                    }
                }
            case let .allDebrid(item):
                let initialFile: AllDebridMagnetFile? = {
                    if case let .magnetFile(file) = item {
                        return file
                    }
                    return nil
                }()
                let initialLink: AllDebridSavedLink? = {
                    if case let .savedLink(link) = item {
                        return link
                    }
                    return nil
                }()

                AllDebridLibraryView(
                    navigationTitle: "AllDebrid",
                    initialFile: initialFile,
                    initialLink: initialLink,
                    onAuthenticated: { selectedSheet = nil },
                    onSignedOut: { selectedSheet = nil },
                )
            }
        }
        .onChange(of: viewModel.contentRevisions) {
            viewModel.refreshAfterContentChanges()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task { await viewModel.refreshIfNeeded() }
        }
    }

    private var backdropMedia: MediaItem? {
        viewModel.heroSlides.first { $0.media.identity == featuredBackdropID }?.media
            ?? viewModel.heroSlides.first?.media
    }

    private var effectiveActions: MediaCardActions? {
        guard viewModel.isServerFree else { return mediaCardActions }
        return MediaCardActions(
            play: { media, _ in play(media) },
            resume: { play($0) },
            showMedia: { select(.playable($0)) },
        )
    }

    private func select(_ media: MediaDisplayItem) {
        guard let catalog = viewModel.catalog, let item = media.playableItem else { onSelectMedia(media); return }
        backdropSelection.select(item)
        if let selection = catalog.selection(for: item) {
            catalogSelection = selection
        } else if let selection = catalog.rawSelection(for: item) {
            selectedSheet = .allDebrid(selection)
        }
    }

    private func play(_ media: MediaItem) {
        guard let catalog = viewModel.catalog else { mediaCardActions?.play(media, false); return }
        backdropSelection.select(media)
        if let selection = catalog.selection(for: media) {
            if selection.title.kind == .tv, selection.episode == nil {
                catalogSelection = selection
            } else {
                selectedSheet = .catalogSources(selection)
            }
        } else if let selection = catalog.rawSelection(for: media) {
            selectedSheet = .allDebrid(selection)
        }
    }
}

#if os(iOS)
    private extension View {
        @ViewBuilder
        func softTopScrollEdge() -> some View {
            if #available(iOS 26.0, *) {
                scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                self
            }
        }
    }
#endif

private struct CatalogHubView: View {
    @Environment(\.dismiss) private var dismiss
    let hub: Hub
    var showsCloseButton = true
    var usesBackdrop = true
    let onSelect: (MediaDisplayItem) -> Void
    var body: some View {
        HubDetailView(viewModel: HubDetailViewModel(hub: hub), onSelectMedia: onSelect)
            .catalogBackdrop(media: hub.items.first?.playableItem, enabled: usesBackdrop)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) { Button("hub.close") { dismiss() } }
                }
            }
    }
}

struct CatalogSearchView: View {
    let data: CatalogHomeData
    var showsCloseButton = true
    let onSelect: (MediaDisplayItem) -> Void
    @State private var query = ""
    var body: some View {
        VStack {
            CatalogHubView(
                hub: data.searchRow.hub,
                showsCloseButton: showsCloseButton,
                usesBackdrop: false,
                onSelect: onSelect,
            )
            .id(data.searchRow.hub)
            if data.isSearching {
                ProgressView()
            }
            if data.hasMoreSearchResults, !data.isSearching {
                Button("Load More") { Task { await data.searchMore() } }.padding()
            }
            if let error = data.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .catalogBackdrop(media: data.searchResults.first.map { CatalogMediaAdapter.make(
            title: $0,
            episode: nil,
            resume: nil,
        ) })
        .navigationTitle("tabs.search")
        .searchable(text: $query, prompt: "Search movies and TV shows")
        .task(id: query) { await data.search(query) }
    }
}
