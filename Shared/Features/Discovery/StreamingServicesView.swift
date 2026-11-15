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
                posters[service.id] = Array((Array(movie.results.prefix(1)) + Array(tv.results.prefix(1))
                        + movie.results.dropFirst().prefix(1) + tv.results.dropFirst().prefix(1)).prefix(2))
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct StreamingServicesSection: View {
    @AppStorage("tmdb.watchRegion") private var region = Locale.current.region?.identifier ?? "US"
    @State private var data = StreamingServicesData()
    @State private var selection: StreamingService?

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
                        Button { selection = service } label: {
                            StreamingServiceCard(
                                service: service,
                                logo: (data.providers(service, kind: .movie)
                                    + data.providers(service, kind: .tv)).first?.logo_path,
                                posters: data.posters[service.id] ?? [],
                            )
                        }.buttonStyle(.plain)
                    }
                }
            }
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
    let logo: String?
    let posters: [TMDBTitle]
    private var tint: Color {
        switch service.id {
        case "netflix": .red
        case "disney", "prime", "paramount": .blue
        case "hulu", "peacock": .green
        case "crunchyroll": .orange
        case "max": .purple
        default: .gray
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [tint.opacity(0.35), Color(white: 0.07), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            )
            HStack {
                Spacer()
                ZStack {
                    ForEach(Array(posters.enumerated()), id: \.element.catalogID) { index, title in
                        TMDBArtwork(path: title.poster_path)
                            .frame(width: 104, height: 156).clipShape(RoundedRectangle(cornerRadius: 10))
                            .rotationEffect(.degrees(index == 0 ? -10 : 9))
                            .offset(x: index == 0 ? -28 : 27, y: index == 0 ? -12 : 17)
                            .shadow(color: .black.opacity(0.6), radius: 10, y: 6)
                    }
                }.frame(width: 155, height: 210)
            }.padding(.trailing, 14)
            VStack(alignment: .leading, spacing: 7) {
                AsyncImage(url: TMDBImageService.imageURL(path: logo, size: .w500)) { image in
                    image.resizable().scaledToFit()
                } placeholder: { Text(service.name).font(.headline) }
                    .frame(width: 54, height: 42, alignment: .leading)
                Text(service.name).font(.title3.bold())
                Text("Streaming").font(.subheadline.weight(.medium))
                Text("Movies · Series").font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.name).font(.subheadline.bold())
                        Text(service.description).font(.caption).lineLimit(2)
                    }
                    Image(systemName: "arrow.right")
                }.frame(width: 162, alignment: .leading)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .frame(width: 350, height: 254)
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
        .navigationTitle(service.name)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .navigationDestination(item: $selection) { TMDBDetailView(title: $0) }
        .task(id: kind) { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard reset || !loading else { return }
        if reset {
            titles = []; page = 0; totalPages = 0
        }
        loading = true
        errorMessage = nil
        let requestedKind = kind
        defer {
            if requestedKind == kind {
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
            guard requestedKind == kind else { return }
            var seen = Set(titles.map(\.catalogID))
            titles += result.results.filter { seen.insert($0.catalogID).inserted }
            page += 1
            totalPages = min(result.total_pages, 500)
        } catch {
            if !Task.isCancelled, requestedKind == kind {
                errorMessage = error.localizedDescription
            }
        }
    }
}
