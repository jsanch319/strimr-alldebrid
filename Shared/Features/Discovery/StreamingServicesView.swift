import SwiftUI

struct StreamingService: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let aliases: [String]

    func matches(_ provider: TMDBClient.WatchProvider) -> Bool {
        aliases.contains(provider.provider_name.lowercased())
    }

    static let all: [Self] = [
        .init(
            id: "netflix",
            name: "Netflix",
            description: "Stories from around the world",
            aliases: ["netflix", "netflix standard with ads"],
        ),
        .init(
            id: "disney",
            name: "Disney+",
            description: "Family favorites and new adventures",
            aliases: ["disney plus", "disney+"],
        ),
        .init(
            id: "max",
            name: "HBO Max",
            description: "Movies and acclaimed series",
            aliases: ["hbo max", "max", "max amazon channel"],
        ),
        .init(
            id: "prime",
            name: "Prime Video",
            description: "Movies, series and originals",
            aliases: ["amazon prime video", "amazon prime video with ads", "prime video"],
        ),
        .init(
            id: "apple",
            name: "Apple TV+",
            description: "Original stories and films",
            aliases: ["apple tv plus", "apple tv+", "apple tv"],
        ),
        .init(id: "hulu", name: "Hulu", description: "Series, films and fresh favorites", aliases: ["hulu"]),
        .init(
            id: "paramount",
            name: "Paramount+",
            description: "Movies and memorable series",
            aliases: ["paramount plus", "paramount+", "paramount plus essential", "paramount+ with showtime"],
        ),
        .init(
            id: "peacock",
            name: "Peacock",
            description: "Entertainment worth discovering",
            aliases: ["peacock", "peacock premium", "peacock premium plus"],
        ),
        .init(
            id: "crunchyroll",
            name: "Crunchyroll",
            description: "Discover the world of anime",
            aliases: ["crunchyroll"],
        ),
    ]
}

@MainActor
@Observable
final class StreamingServicesData {
    var movies: [TMDBClient.WatchProvider] = []
    var shows: [TMDBClient.WatchProvider] = []
    var regions: [TMDBClient.WatchRegion] = []
    var posters: [String: [TMDBTitle]] = [:]
    var errorMessage: String?

    func providers(_ service: StreamingService, kind: TMDBTitle.Kind) -> [TMDBClient.WatchProvider] {
        (kind == .movie ? movies : shows).filter(service.matches)
    }

    func load(region: String) async {
        errorMessage = nil
        posters = [:]
        do {
            let client = TMDBClient.shared
            movies = try await client.watchProviders(kind: .movie)
            shows = try await client.watchProviders(kind: .tv)
            regions = try await client.watchRegions()
            for service in StreamingService.all {
                try Task.checkCancellation()
                let movie = try await client.providerTitles(
                    ids: providers(service, kind: .movie).map(\.provider_id),
                    kind: .movie,
                    region: region,
                )
                let tv = try await client.providerTitles(
                    ids: providers(service, kind: .tv).map(\.provider_id),
                    kind: .tv,
                    region: region,
                )
                try Task.checkCancellation()
                let filmPosters = movie.results.filter { $0.poster_path != nil }
                let tvPosters = tv.results.filter { $0.poster_path != nil }
                posters[service.id] = Array((Array(filmPosters.prefix(1)) + Array(tvPosters.prefix(1))
                        + filmPosters.dropFirst().prefix(1) + tvPosters.dropFirst().prefix(1)).prefix(2))
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct StreamingServicesSection: View {
    @Environment(\.catalogBackdropSelection) private var catalogBackdrop
    @AppStorage("tmdb.watchRegion") private var region = Locale.current.region?.identifier ?? "US"
    @State private var data = StreamingServicesData()
    @State private var selection: StreamingService?
    @State private var availableWidth: CGFloat = 390

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Streaming Services").font(.title2.bold())
                Spacer()
                Picker("Region", selection: $region) {
                    if !data.regions.contains(where: { $0.id == region }) {
                        Text(region).tag(region)
                    }
                    ForEach(data.regions) { Text($0.english_name).tag($0.id) }
                }.labelsHidden()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(StreamingService.all) { service in
                        Button {
                            if let title = data.posters[service.id]?.first {
                                catalogBackdrop?.select(CatalogMediaAdapter.make(
                                    title: title,
                                    episode: nil,
                                    resume: nil,
                                ))
                            }
                            selection = service
                        } label: {
                            StreamingServiceCard(
                                service: service,
                                width: min(560, max(280, availableWidth * 0.94)),
                                logo: (data.providers(service, kind: .movie)
                                    + data.providers(service, kind: .tv)).first?.logo_path,
                                posters: data.posters[service.id] ?? [],
                            )
                        }.buttonStyle(.plain)
                            .catalogBackdropCandidate(data.posters[service.id]?.first.map { CatalogMediaAdapter.make(
                                title: $0,
                                episode: nil,
                                resume: nil,
                            ) })
                    }
                }.scrollTargetLayout()
                    .padding(.vertical, 8)
            }
            .scrollTargetBehavior(.viewAligned)
            .posterRailNavigation()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            if let error = data.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { Task { await data.load(region: region) } }
            }
            Text("Subscription catalogs in \(region) · Availability data by TMDb / JustWatch")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: region) { await data.load(region: region) }
        .sheet(item: $selection) { service in
            NavigationStack {
                StreamingProviderView(
                    service: service,
                    region: region,
                    movieIDs: data.providers(service, kind: .movie).map(\.provider_id),
                    tvIDs: data.providers(service, kind: .tv).map(\.provider_id),
                )
            }
        }
    }
}

private struct StreamingServiceCard: View {
    let service: StreamingService
    let width: CGFloat
    let logo: String?
    let posters: [TMDBTitle]
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 235
    private var height: CGFloat {
        max(minimumHeight, width * 0.64)
    }

    private var tint: Color {
        switch service.id {
        case "netflix": .red
        case "disney": .cyan
        case "prime", "paramount": .blue
        case "hulu", "peacock": .green
        case "crunchyroll": .orange
        case "max": .purple
        default: .gray
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [Color(white: 0.055), tint.opacity(0.3), Color(white: 0.09)],
                startPoint: .bottomLeading,
                endPoint: .topTrailing,
            )
            ZStack {
                ForEach(Array(posters.enumerated()), id: \.element.catalogID) { index, title in
                    TMDBArtwork(path: title.poster_path)
                        .frame(width: width * 0.29, height: width * 0.435)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .rotationEffect(.degrees(index == 0 ? -11 : 8))
                        .offset(
                            x: index == 0 ? -width * 0.065 : width * 0.075,
                            y: index == 0 ? -height * 0.045 : height * 0.06,
                        )
                        .shadow(color: .black.opacity(0.65), radius: 14, y: 8)
                }
            }
            .frame(width: width * 0.46, height: height)
            .frame(maxWidth: .infinity, alignment: .trailing)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.4), location: 0),
                    .init(color: .black.opacity(0.15), location: 0.45),
                    .init(color: .clear, location: 0.67),
                ],
                startPoint: .leading,
                endPoint: .trailing,
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    AsyncImage(url: TMDBImageService.imageURL(path: logo, size: .w500)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text(service.name).font(.caption.bold()).minimumScaleFactor(0.6)
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.name).font(.subheadline.weight(.semibold))
                        Text("Streaming").font(.caption.weight(.medium))
                        Text("Movies · Series").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 20)
                VStack(alignment: .leading, spacing: 7) {
                    Text(service.name).font(.title2.bold())
                    Text(service.description).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    Image(systemName: "arrow.right").font(.subheadline.weight(.semibold)).padding(.top, 3)
                }
                .frame(width: width * 0.45, alignment: .leading)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 6, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(service.name), streaming movies and series")
    }
}

private struct StreamingProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsManager.self) private var settingsManager
    let service: StreamingService
    let region: String
    let movieIDs: [Int]
    let tvIDs: [Int]
    @State private var kind = TMDBTitle.Kind.movie
    @State private var titles: [TMDBTitle] = []
    @State private var selection: TMDBTitle?
    @State private var page = 0
    @State private var totalPages = 0
    @State private var generation = UUID()
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Picker("Catalog", selection: $kind) {
                Text("Movies").tag(TMDBTitle.Kind.movie)
                Text("TV Shows").tag(TMDBTitle.Kind.tv)
            }.pickerStyle(.segmented).padding(.horizontal, LayoutMetrics.pageMargin)
            Text("\(region) subscriptions · Play available files through AllDebrid")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                PosterGrid(spacing: 12, rowSpacing: 20) { width in
                    ForEach(titles, id: \.catalogID) { title in
                        PortraitMediaCard(
                            media: .playable(CatalogMediaAdapter.make(
                                title: title,
                                episode: nil,
                                resume: nil,
                            )),
                            width: width,
                            showsLabels: settingsManager.interface.showsCardLabels,
                        ) {
                            selection = title
                        }
                        .onAppear {
                            if titles.suffix(4).contains(where: { $0.catalogID == title.catalogID }),
                               page < totalPages, !loading, errorMessage == nil
                            {
                                Task { await load(reset: false) }
                            }
                        }
                    }
                }.padding(.horizontal, LayoutMetrics.pageMargin)
                if loading {
                    ProgressView().padding()
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary).padding()
                    Button("Retry") { Task { await load(reset: false) } }
                } else if !loading, titles.isEmpty {
                    ContentUnavailableView("No titles available in \(region)", systemImage: "film")
                }
                if !loading, page < totalPages {
                    Button("Load More") { Task { await load(reset: false) } }.padding()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("catalog.provider.content")
        .catalogBackdrop(media: titles.first.map { CatalogMediaAdapter.make(title: $0, episode: nil, resume: nil) })
        .navigationTitle(service.name)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .navigationDestination(item: $selection) { TMDBDetailView(title: $0) }
        .task(id: kind) { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard reset || (!loading && (page == 0 || page < totalPages)) else { return }
        if reset {
            generation = UUID()
            titles = []; page = 0; totalPages = 0
        }
        loading = true
        errorMessage = nil
        let requestGeneration = generation
        let requestedKind = kind
        defer {
            if requestedKind == kind, requestGeneration == generation {
                loading = false
            }
        }
        do {
            let result = try await TMDBClient.shared.providerTitles(
                ids: kind == .movie ? movieIDs : tvIDs,
                kind: kind,
                region: region,
                page: page + 1,
            )
            try Task.checkCancellation()
            guard requestedKind == kind, requestGeneration == generation else { return }
            var seen = Set(titles.map(\.catalogID))
            titles += result.results.filter { seen.insert($0.catalogID).inserted }
            page += 1
            totalPages = result.results.isEmpty ? page : min(result.total_pages, 500)
        } catch {
            if !Task.isCancelled, requestedKind == kind, requestGeneration == generation {
                errorMessage = error.localizedDescription
            }
        }
    }
}
