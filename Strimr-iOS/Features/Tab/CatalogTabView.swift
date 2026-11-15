import SwiftUI

/// Uses the same native Tab/NavigationStack/More pattern as MainTabView, without media-server services.
struct CatalogTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State var homeViewModel: HomeViewModel
    @State private var selectedTab = CatalogTab.home
    @State private var paths: [CatalogTab: NavigationPath] = [:]

    private var layout: CatalogTabLayout {
        // Keep the native bar at the bottom, including regular-width iOS windows.
        CatalogTabLayout(isCompact: true)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: CatalogTab.home) { stack(.home) }
            Tab("Search", systemImage: "magnifyingglass", value: CatalogTab.search, role: .search) { stack(.search) }
            Tab("Movies", systemImage: "film.fill", value: CatalogTab.movies) { stack(.movies) }
            Tab("TV Shows", systemImage: "tv", value: CatalogTab.tvShows) { stack(.tvShows) }
            if layout.bar.contains(.myList) {
                Tab("My List", systemImage: "bookmark.fill", value: CatalogTab.myList) { stack(.myList) }
            }
            if layout.bar.contains(.settings) {
                Tab("Settings", systemImage: "gearshape.fill", value: CatalogTab.settings) { stack(.settings) }
            }
            if !layout.overflow.isEmpty {
                Tab("More", systemImage: "ellipsis", value: CatalogTab.more) { more }
            }
        }
        .environment(\.isCatalogNavigation, true)
        .tabViewStyle(.tabBarOnly)
        .environment(\.horizontalSizeClass, .compact)
    }

    private func path(_ tab: CatalogTab) -> Binding<NavigationPath> {
        Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })
    }

    private func stack(_ tab: CatalogTab) -> some View {
        NavigationStack(path: path(tab)) { root(tab) }
            .environment(\.horizontalSizeClass, horizontalSizeClass)
    }

    private var more: some View {
        NavigationStack(path: path(.more)) {
            List(layout.overflow) { tab in
                NavigationLink(value: tab) { Label(tab.title, systemImage: tab.symbol) }
            }
            .navigationTitle("tabs.overflow")
            .tabRootChrome()
            .navigationDestination(for: CatalogTab.self) { tab in
                root(tab)
            }
        }
        .environment(\.horizontalSizeClass, horizontalSizeClass)
    }

    @ViewBuilder private func root(_ tab: CatalogTab) -> some View {
        if let data = homeViewModel.catalog {
            switch tab {
            case .home: HomeView(viewModel: homeViewModel)
            case .search: CatalogSearchTab(data: data)
            case .movies, .tvShows: CatalogBrowseTab(tab: tab, data: data)
            case .myList: CatalogWatchlistTab()
            case .settings:
                SettingsView(catalogMode: true, onCatalogChanged: {
                    Task { await data.load(force: true) }
                })
                .tabRootChrome()
            case .more: EmptyView() // Container only, never a destination.
            }
        }
    }
}

private struct CatalogSearchTab: View {
    let data: CatalogHomeData
    @State private var selection: TMDBTitle?
    var body: some View {
        CatalogSearchView(data: data, showsCloseButton: false, onSelect: { media in
            guard let item = media.playableItem else { return }
            selection = data.selection(for: item)?.title
        })
        .tabRootChrome()
        .navigationDestination(item: $selection) { TMDBDetailView(title: $0) }
    }
}

private struct CatalogBrowseTab: View {
    let tab: CatalogTab
    let data: CatalogHomeData
    private var kind: TMDBTitle.Kind {
        tab == .movies ? .movie : .tv
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(tab.feeds) { feed in
                    if let titles = data.feeds[feed], !titles.isEmpty {
                        TMDBPosterRow(heading: feed.title, titles: titles)
                    }
                }
                let recommended = data.recommendations.filter { $0.kind == kind }
                if !recommended.isEmpty {
                    TMDBPosterRow(heading: "Recommended For You", titles: recommended)
                }
                if let error = data.errorMessage {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await data.load(force: true) } }
                } else if tab.feeds.allSatisfy({ data.feeds[$0] == nil }) {
                    ProgressView()
                }
            }
            .padding(.horizontal, LayoutMetrics.pageMargin)
            .padding(.vertical, 20)
        }
        .catalogBackdrop(media: tab.feeds.compactMap { data.feeds[$0]?.first }.first.map {
            CatalogMediaAdapter.make(title: $0, episode: nil, resume: nil)
        })
        .navigationTitle(tab.title)
        .tabRootChrome()
        .task {
            if tab.feeds.contains(where: { data.feeds[$0] == nil }) {
                await data.load()
            }
        }
        .refreshable { await data.load(force: true) }
    }
}

private struct CatalogWatchlistTab: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var kind = "all"
    @State private var selection: TMDBTitle?
    private let discovery = DiscoveryStore.shared
    private var entries: [SimklListEntry] {
        discovery.planned.filter { kind == "all" || $0.kind.rawValue == kind }
    }

    private var titles: [TMDBTitle] {
        var seen = Set<String>()
        return entries.compactMap { discovery.title(for: $0) }.filter { seen.insert($0.catalogID).inserted }
    }

    var body: some View {
        VStack {
            Picker("My List", selection: $kind) {
                Text("All").tag("all")
                Text("Movies").tag("movie")
                Text("TV Shows").tag("tv")
            }.pickerStyle(.segmented).padding(.horizontal, LayoutMetrics.pageMargin)
            ScrollView {
                PosterGrid(spacing: 12, rowSpacing: 20) { width in
                    ForEach(titles, id: \.catalogID) { title in
                        PortraitMediaCard(
                            media: .playable(CatalogMediaAdapter.make(title: title, episode: nil, resume: nil)),
                            width: width,
                            showsLabels: settingsManager.interface.showsCardLabels,
                        ) { selection = title }
                    }
                }.padding(.horizontal, LayoutMetrics.pageMargin)
                ForEach(entries.filter { $0.catalogID == nil }) { entry in
                    Text("\(entry.media?.title ?? "Unmapped title") · No verified TMDb match")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, LayoutMetrics.pageMargin)
                }
                if discovery.isSyncing {
                    ProgressView().padding()
                }
                if let error = discovery.errorMessage {
                    Text(error).foregroundStyle(.secondary).padding()
                }
                if entries.isEmpty, !discovery.isSyncing {
                    ContentUnavailableView(
                        "My List is empty",
                        systemImage: "bookmark",
                        description: Text("Connect Simkl and add movies or series to Plan to Watch."),
                    )
                }
                NavigationLink("Simkl Account") { TrackerSettingsView(service: .simkl) }.padding()
            }
            .refreshable { await discovery.sync(force: true) }
        }
        .catalogBackdrop(media: titles.first.map { CatalogMediaAdapter.make(title: $0, episode: nil, resume: nil) })
        .navigationTitle("My List")
        .tabRootChrome()
        .navigationDestination(item: $selection) { TMDBDetailView(title: $0) }
        .task(id: discovery.accountKey) { await discovery.sync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await discovery.sync() }
            }
        }
        .onAppear { Task { await discovery.sync() } }
    }
}
