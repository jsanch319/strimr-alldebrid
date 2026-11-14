import AVKit
import SwiftUI

/// Independent, experimental AllDebrid library. It does not impersonate a Plex server.
struct AllDebridLibraryView: View {
    @State private var apiKey = ""
    @State private var links: [AllDebridSavedLink] = []
    @State private var magnetFiles: [AllDebridMagnetFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var activeSheet: ActiveSheet?
    @State private var isConfigured = false

    private enum ActiveSheet: Identifiable {
        case player(URL)
        case sources(AllDebridMagnetFile)

        var id: String {
            switch self {
            case let .player(url): "player:\(url.absoluteString)"
            case let .sources(file): "sources:\(file.id)"
            }
        }
    }

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
                                ForEach(Self.selectBestVideos(magnetFiles)) { file in
                                    magnetRow(file)
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
                                activeSheet = nil
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
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case let .player(playerURL):
                    AllDebridVideoPlayer(url: playerURL)
                case let .sources(file):
                    AllDebridSourcePicker(
                        magnetTitle: Self.cleanTitle(file.filename),
                        sources: Self.sources(for: file.magnetID, in: magnetFiles),
                    ) { source in
                        play(source)
                    }
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
            let files = try await client.magnetFiles(for: readyMagnets.map(\.id))
            links = savedLinks.filter(\.isVideo)
            magnetFiles = files.filter(\.isVideo)
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
            activeSheet = try await .player(client.unlock(link.link))
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
        activeSheet = .player(url)
    }

    private func magnetRow(_ file: AllDebridMagnetFile) -> some View {
        HStack(spacing: 12) {
            Button {
                play(file)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "film").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.cleanTitle(file.filename)).font(.headline)
                        Text(file.fullPath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "play.circle.fill")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(Self.cleanTitle(file.filename))")

            Button {
                activeSheet = .sources(file)
            } label: {
                Image(systemName: "list.bullet")
                    .frame(minWidth: 32, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Select Source")
        }
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
        let candidates = files.filter { $0.isVideo && $0.size >= 0 && $0.size <= automaticMaximumSize }
        let groups = Dictionary(grouping: candidates) {
            "\($0.magnetID):\(cleanTitle($0.filename).lowercased())"
        }
        return groups.values.compactMap { versions in
            versions.max {
                sourcePrecedes($1, $0)
            }
        }
        .sorted {
            if $0.magnetID != $1.magnetID {
                return $0.magnetID < $1.magnetID
            }
            return $0.fullPath < $1.fullPath
        }
    }

    static func sources(for magnetID: String, in files: [AllDebridMagnetFile]) -> [AllDebridMagnetFile] {
        files
            .filter { $0.magnetID == magnetID && $0.isVideo }
            .sorted(by: sourcePrecedes)
    }

    private static let automaticMaximumSize: Int64 = 20 * 1024 * 1024 * 1024

    private static func sourcePrecedes(_ lhs: AllDebridMagnetFile, _ rhs: AllDebridMagnetFile) -> Bool {
        let leftResolution = resolutionRank(lhs.filename)
        let rightResolution = resolutionRank(rhs.filename)
        if leftResolution != rightResolution {
            return leftResolution > rightResolution
        }
        if lhs.size != rhs.size {
            return lhs.size > rhs.size
        }
        return lhs.fullPath < rhs.fullPath
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

    static func sourceDetails(_ file: AllDebridMagnetFile) -> String {
        let name = file.filename.lowercased()
        var details = [resolutionLabel(file.filename)]

        if name.range(of: #"\b(hevc|h\.?265|x265)\b"#, options: .regularExpression) != nil {
            details.append("HEVC / H.265")
        } else if name.range(of: #"\b(h\.?264|x264|avc)\b"#, options: .regularExpression) != nil {
            details.append("H.264")
        } else if name.range(of: #"\bav1\b"#, options: .regularExpression) != nil {
            details.append("AV1")
        }

        if name.range(of: #"\b(dolby[ ._-]?vision|dovi|dv)\b"#, options: .regularExpression) != nil {
            details.append("Dolby Vision")
        }
        if name.range(of: #"\bhdr10\+?\b"#, options: .regularExpression) != nil,
           !details.contains("Dolby Vision")
        {
            details.append("HDR10")
        } else if name.range(of: #"\bhdr\b"#, options: .regularExpression) != nil,
                  !details.contains("Dolby Vision"), !details.contains("HDR10")
        {
            details.append("HDR")
        }
        details.append(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
        return details.joined(separator: " • ")
    }

    private static func resolutionLabel(_ filename: String) -> String {
        let name = filename.lowercased()
        if name.range(of: #"\b2160p\b"#, options: .regularExpression) != nil {
            return "2160p"
        }
        if name.range(of: #"\b4k\b"#, options: .regularExpression) != nil {
            return "4K"
        }
        if name.range(of: #"\b1080p\b"#, options: .regularExpression) != nil {
            return "1080p"
        }
        if name.range(of: #"\b720p\b"#, options: .regularExpression) != nil {
            return "720p"
        }
        return "Resolution unknown"
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

private struct AllDebridSourcePicker: View {
    @Environment(\.dismiss) private var dismiss

    let magnetTitle: String
    let sources: [AllDebridMagnetFile]
    let onSelect: (AllDebridMagnetFile) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(sources) { source in
                    Button {
                        onSelect(source)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AllDebridLibraryView.cleanTitle(source.filename))
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(AllDebridLibraryView.sourceDetails(source))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(source.fullPath)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(AllDebridLibraryView.cleanTitle(source.filename)), \(AllDebridLibraryView.sourceDetails(source))",
                    )
                }
            }
            .navigationTitle("Select Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("AllDebridSourcePicker")
        .overlay {
            if sources.isEmpty {
                ContentUnavailableView(
                    "No playable sources",
                    systemImage: "film",
                    description: Text(magnetTitle),
                )
            }
        }
    }
}
