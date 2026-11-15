import SwiftUI

enum AllDebridHomeItem: Identifiable {
    case library
    case savedLink(AllDebridSavedLink)
    case magnetFile(AllDebridMagnetFile)

    var id: String {
        switch self {
        case .library: "library"
        case let .savedLink(link): "link:\(link.id)"
        case let .magnetFile(file): "magnet:\(file.id)"
        }
    }
}

@MainActor
struct AllDebridHomeSection: View {
    let onSelect: (AllDebridHomeItem) -> Void
    var onAccountAvailabilityChange: (Bool) -> Void = { _ in }

    @State private var savedLinks: [AllDebridSavedLink] = []
    @State private var magnetFiles: [AllDebridMagnetFile] = []
    @State private var isConfigured = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AllDebrid", systemImage: "play.tv")
                    .font(.headline)
                Spacer()
                Button("See All") { onSelect(.library) }
                    .font(.subheadline.weight(.semibold))
            }

            if isLoading, savedLinks.isEmpty, magnetFiles.isEmpty {
                ProgressView("Loading AllDebrid…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !isConfigured {
                Text("Connect AllDebrid to show its saved links and ready magnet videos on Home.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button("Connect AllDebrid") { onSelect(.library) }
                    .buttonStyle(.bordered)
            } else {
                ForEach(savedLinks.prefix(3)) { link in
                    Button {
                        onSelect(.savedLink(link))
                    } label: {
                        homeRow(title: AllDebridLibraryView.cleanTitle(link.filename), subtitle: link.filename)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(AllDebridLibraryView.selectBestVideos(magnetFiles).prefix(5)) { file in
                    Button {
                        onSelect(.magnetFile(file))
                    } label: {
                        homeRow(title: AllDebridLibraryView.cleanTitle(file.filename), subtitle: file.fullPath)
                    }
                    .buttonStyle(.plain)
                }

                if savedLinks.isEmpty, !magnetFiles.contains(where: \.isVideo), !isLoading, errorMessage == nil {
                    Text("No playable AllDebrid videos found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage, isConfigured {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .task {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .allDebridCredentialsDidChange)) { _ in
            Task { await refresh() }
        }
    }

    private func homeRow(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let key = try AllDebridCredentialStore().load() else {
                isConfigured = false
                savedLinks = []
                magnetFiles = []
                errorMessage = nil
                onAccountAvailabilityChange(false)
                return
            }
            isConfigured = true
            onAccountAvailabilityChange(true)
            let snapshot = try await AllDebridAPIClient(apiKey: key).librarySnapshot()
            savedLinks = snapshot.savedLinks.filter(\.isVideo)
            magnetFiles = snapshot.magnetFiles
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct AllDebridOnlyHomeView: View {
    @State private var selectedItem: AllDebridHomeItem?
    let onSignedOut: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                AllDebridHomeSection { item in
                    selectedItem = item
                }
                .padding(.horizontal, LayoutMetrics.pageMargin)
                .padding(.vertical, 20)
            }
            .navigationTitle("tabs.home")
            .sheet(item: $selectedItem) { item in
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
                    onAuthenticated: { selectedItem = nil },
                    onSignedOut: {
                        selectedItem = nil
                        onSignedOut()
                    },
                )
            }
        }
    }
}
