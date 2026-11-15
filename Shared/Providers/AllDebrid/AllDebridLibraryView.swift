import AetherEngine
import OSLog
import SwiftUI

/// Independent, experimental AllDebrid library. It does not impersonate a Plex server.
struct AllDebridLibraryView: View {
    private static let logger = Logger(subsystem: "com.strimr", category: "AllDebrid")

    private let onAuthenticated: (() -> Void)?
    private let onSignedOut: (() -> Void)?
    private let initialFile: AllDebridMagnetFile?
    private let initialLink: AllDebridSavedLink?
    private let navigationTitle: String
    @State private var apiKey = ""
    @State private var links: [AllDebridSavedLink] = []
    @State private var magnetFiles: [AllDebridMagnetFile] = []
    @State private var totalMagnetCount = 0
    @State private var readyMagnetCount = 0
    @State private var hasLoadedLibrary = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var activeSheet: ActiveSheet?
    @State private var isConfigured = false

    init(
        navigationTitle: String = "AllDebrid Movies",
        initialFile: AllDebridMagnetFile? = nil,
        initialLink: AllDebridSavedLink? = nil,
        onAuthenticated: (() -> Void)? = nil,
        onSignedOut: (() -> Void)? = nil,
    ) {
        self.navigationTitle = navigationTitle
        self.initialFile = initialFile
        self.initialLink = initialLink
        self.onAuthenticated = onAuthenticated
        self.onSignedOut = onSignedOut
    }

    private enum ActiveSheet: Identifiable {
        case savedPlayer(link: AllDebridSavedLink, url: URL)
        case magnetPlayer(file: AllDebridMagnetFile, url: URL)
        case sources(AllDebridMagnetFile)

        var id: String {
            switch self {
            case let .savedPlayer(link, _): "saved-player:\(link.id)"
            case let .magnetPlayer(file, _): "magnet-player:\(file.id)"
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
                        if hasLoadedLibrary,
                           !isLoading,
                           errorMessage == nil,
                           links.isEmpty,
                           !magnetFiles.contains(where: \.isVideo)
                        {
                            ContentUnavailableView(
                                Self.emptyLibraryMessage(
                                    totalMagnets: totalMagnetCount,
                                    readyMagnets: readyMagnetCount,
                                ),
                                systemImage: "film",
                            )
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
            .navigationTitle(navigationTitle)
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
                                totalMagnetCount = 0
                                readyMagnetCount = 0
                                hasLoadedLibrary = false
                                isConfigured = false
                                activeSheet = nil
                                onSignedOut?()
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
                Group {
                    switch sheet {
                    case let .savedPlayer(link, url):
                        AllDebridFilePlayer(
                            media: CatalogMediaAdapter.raw(id: "saved:\(link.id)", filename: link.filename),
                            url: url,
                            externalSubtitles: [],
                        )
                    case let .magnetPlayer(file, url):
                        AllDebridFilePlayer(
                            media: CatalogMediaAdapter.raw(id: "magnet:\(file.id)", filename: file.filename),
                            url: url,
                            externalSubtitles: AllDebridSubtitleMatcher.externalTracks(for: file, in: magnetFiles),
                        )
                    case let .sources(file):
                        AllDebridSourcePicker(
                            magnetTitle: Self.cleanTitle(file.filename),
                            sources: Self.sources(for: file.magnetID, in: magnetFiles),
                            subtitleFiles: magnetFiles.filter { $0.magnetID == file.magnetID && $0.isSubtitle },
                        ) { source in
                            Task { await play(source) }
                        }
                    }
                }
            }
            .task {
                do {
                    if let key = try AllDebridCredentialStore().load() {
                        apiKey = key
                        isConfigured = true
                        try await refresh(using: key)
                        if let initialFile {
                            await play(initialFile)
                        } else if let initialLink {
                            await play(initialLink)
                        }
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func connect() async {
        let authenticatedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AllDebridCredentialStore().save(authenticatedKey)
            apiKey = authenticatedKey
            isConfigured = true
            Self.logger.debug("AllDebrid login succeeded and credentials were saved")
            do {
                try await refresh(using: authenticatedKey)
            } catch {
                errorMessage = error.localizedDescription
            }
            onAuthenticated?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        do {
            try await refresh(using: apiKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh(using key: String) async throws {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        let client = try AllDebridAPIClient(apiKey: key)
        let snapshot = try await client.librarySnapshot()

        links = snapshot.savedLinks.filter(\.isVideo)
        magnetFiles = snapshot.magnetFiles
        totalMagnetCount = snapshot.magnets.count
        readyMagnetCount = snapshot.readyMagnetCount
        hasLoadedLibrary = true
        Self.logger.debug(
            "AllDebrid refresh complete: savedLinksReturned=\(snapshot.savedLinks.count), videoLinks=\(links.count), magnetsReturned=\(snapshot.magnets.count), readyMagnets=\(snapshot.readyMagnetCount), magnetFilesReturned=\(snapshot.magnetFiles.count), playableVideoCandidates=\(snapshot.magnetFiles.filter(\.isVideo).count)",
        )
    }

    private func play(_ link: AllDebridSavedLink) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try AllDebridAPIClient(apiKey: apiKey)
            let resolution = try await client.resolvePlaybackURL(link.link, filename: link.filename)
            activeSheet = .savedPlayer(link: link, url: resolution.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func play(_ file: AllDebridMagnetFile) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try AllDebridAPIClient(apiKey: apiKey)
            let resolution = try await client.resolvePlaybackURL(file.link, filename: file.filename)
            activeSheet = .magnetPlayer(file: file, url: resolution.url)
        } catch {
            activeSheet = nil
            errorMessage = error.localizedDescription
        }
    }

    private func magnetRow(_ file: AllDebridMagnetFile) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await play(file) }
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

    static func emptyLibraryMessage(totalMagnets: Int, readyMagnets: Int) -> String {
        totalMagnets > 0 && readyMagnets == 0
            ? "No ready AllDebrid videos found yet."
            : "No playable AllDebrid videos found."
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

@MainActor
private struct AllDebridFilePlayer: View {
    @State private var viewModel: PlayerViewModel
    init(media: MediaItem, url: URL, externalSubtitles: [ExternalSubtitleTrack]) {
        _viewModel = State(initialValue: PlayerViewModel(
            localMedia: media,
            localPlaybackURL: url,
            localExternalSubtitles: externalSubtitles,
        ))
    }

    var body: some View {
        NativePlaybackView(viewModel: viewModel)
    }
}

private struct AllDebridSourcePicker: View {
    @Environment(\.dismiss) private var dismiss

    let magnetTitle: String
    let sources: [AllDebridMagnetFile]
    let subtitleFiles: [AllDebridMagnetFile]
    let onSelect: (AllDebridMagnetFile) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(sources) { source in
                    let subtitleCount = AllDebridSubtitleMatcher.subtitles(for: source, in: subtitleFiles).count
                    let subtitleLabel = "\(subtitleCount) subtitle \(subtitleCount == 1 ? "track" : "tracks")"
                    let sourceTitle = AllDebridLibraryView.cleanTitle(source.filename)
                    let sourceDetails = AllDebridLibraryView.sourceDetails(source)
                    Button {
                        onSelect(source)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sourceTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(sourceDetails)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if subtitleCount > 0 {
                                Text(subtitleLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                        "\(sourceTitle), \(sourceDetails)\(subtitleCount > 0 ? ", \(subtitleLabel)" : "")",
                    )
                }
            }
            .navigationTitle("Select Source")
            .allDebridSourcePickerTitleDisplayMode()
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

private extension View {
    func allDebridSourcePickerTitleDisplayMode() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }
}
