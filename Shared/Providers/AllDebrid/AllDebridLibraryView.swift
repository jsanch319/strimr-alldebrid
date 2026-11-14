import AVKit
import SwiftUI

/// Independent, experimental AllDebrid library. It does not impersonate a Plex server.
struct AllDebridLibraryView: View {
    @State private var apiKey = ""
    @State private var links: [AllDebridSavedLink] = []
    @State private var magnetFiles: [AllDebridMagnetFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var playerURL: URL?
    @State private var showPlayer = false
    @State private var isConfigured = false

    private var refreshToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
            .primaryAction
        #else
            .topBarTrailing
        #endif
    }

    private var signOutToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
            .automatic
        #else
            .topBarLeading
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isConfigured {
                    Form {
                        Section("AllDebrid API key") {
                            SecureField("Paste API key", text: $apiKey)
                                .textContentType(.password)
                                .autocorrectionDisabled()
                            Button("Save and load library") { Task { await connect() } }
                                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                        }
                        Section {
                            Text(
                                "Your key is saved in the iOS Keychain, not in the project files. This experimental screen reads saved links and ready magnet files.",
                            )
                            .font(.footnote)
                        }
                    }
                } else {
                    List {
                        if links.isEmpty, magnetFiles.isEmpty, !isLoading {
                            ContentUnavailableView("No playable AllDebrid videos found.", systemImage: "film")
                        }
                        if !links.isEmpty {
                            Section("Saved Links") {
                                ForEach(links) { link in
                                    Button {
                                        Task { await play(link) }
                                    } label: {
                                        libraryRow(title: Self.cleanTitle(link.filename), subtitle: link.filename)
                                    }
                                }
                            }
                        }
                        if !magnetFiles.isEmpty {
                            Section("Magnets") {
                                ForEach(magnetFiles) { file in
                                    Button {
                                        play(file)
                                    } label: {
                                        libraryRow(
                                            title: Self.cleanTitle(file.filename),
                                            subtitle: file.fullPath,
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .refreshable { await refresh() }
                }
            }
            .navigationTitle("AllDebrid Movies")
            .toolbar {
                if isConfigured {
                    ToolbarItem(placement: refreshToolbarPlacement) {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    }
                    ToolbarItem(placement: signOutToolbarPlacement) {
                        Button("Sign out") {
                            do {
                                try AllDebridCredentialStore().delete()
                                apiKey = ""
                                links = []
                                magnetFiles = []
                                isConfigured = false
                                playerURL = nil
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading…")
                }
            }
            .alert(
                "AllDebrid",
                isPresented: Binding(get: { errorMessage != nil }, set: {
                    if !$0 {
                        errorMessage = nil
                    }
                }),
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "Unknown error") }
            .sheet(isPresented: $showPlayer, onDismiss: { playerURL = nil }) {
                if let playerURL {
                    AllDebridVideoPlayer(url: playerURL)
                }
            }
            .task {
                do {
                    if let key = try AllDebridCredentialStore().load() {
                        apiKey = key
                        isConfigured = true
                        await refresh()
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func connect() async {
        await refresh()
        if errorMessage == nil {
            do {
                try AllDebridCredentialStore().save(apiKey)
                isConfigured = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try AllDebridAPIClient(apiKey: apiKey)
            async let savedLinksTask = client.savedLinks()
            async let readyMagnetsTask = client.readyMagnets()
            let (savedLinks, readyMagnets) = try await (savedLinksTask, readyMagnetsTask)
            let playableFiles = try await client.magnetFiles(for: readyMagnets.map(\.id))
            links = savedLinks.filter(\.isVideo)
            magnetFiles = Self.selectBestVideos(playableFiles)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func play(_ link: AllDebridSavedLink) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try AllDebridAPIClient(apiKey: apiKey)
            playerURL = try await client.unlock(link.link)
            showPlayer = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func play(_ file: AllDebridMagnetFile) {
        guard let url = URL(string: file.link),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else {
            errorMessage = "The playback link is invalid."
            return
        }
        playerURL = url
        showPlayer = true
    }

    private func libraryRow(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "play.circle.fill")
        }
    }

    static func selectBestVideos(_ files: [AllDebridMagnetFile]) -> [AllDebridMagnetFile] {
        let maximumSize: Int64 = 20 * 1024 * 1024 * 1024
        let candidates = files.filter { $0.isVideo && (0 ... maximumSize).contains($0.size) }
        let groups = Dictionary(grouping: candidates) {
            "\($0.magnetID):\(cleanTitle($0.filename).lowercased())"
        }
        return groups.values.compactMap { versions in
            versions.max {
                let leftResolution = resolutionRank($0.filename)
                let rightResolution = resolutionRank($1.filename)
                if leftResolution != rightResolution {
                    return leftResolution < rightResolution
                }
                if $0.size != $1.size {
                    return $0.size < $1.size
                }
                return $0.fullPath > $1.fullPath
            }
        }
        .sorted {
            if $0.magnetID != $1.magnetID {
                return $0.magnetID < $1.magnetID
            }
            return $0.fullPath < $1.fullPath
        }
    }

    private static func resolutionRank(_ filename: String) -> Int {
        let name = filename.lowercased()
        if name.range(of: #"\b(2160p|4k)\b"#, options: .regularExpression) != nil {
            return 3
        }
        if name.range(of: #"\b1080p\b"#, options: .regularExpression) != nil {
            return 2
        }
        if name.range(of: #"\b720p\b"#, options: .regularExpression) != nil {
            return 1
        }
        return 0
    }

    static func cleanTitle(_ filename: String) -> String {
        let basename = (filename as NSString).deletingPathExtension
        let groupTrimmed = basename.replacingOccurrences(
            of: #"(?i)-[a-z0-9]{2,}$"#,
            with: "",
            options: .regularExpression,
        )
        let pattern =
            #"(?i)[ ._-]+\b(2160p|4k|1080p|720p|web[- ]?dl|web[- ]?rip|bluray|blu[- ]?ray|remux|x26[45]|h26[45]|hevc|av1|hdr10?|dovi|dv|aac|dts|proper|repack)\b.*$"#
        let withoutClutter = groupTrimmed.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        let separators = withoutClutter.replacingOccurrences(of: ".", with: " ").replacingOccurrences(
            of: "_",
            with: " ",
        )
        return separators.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AllDebridVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else {
                ProgressView()
            }
        }
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
