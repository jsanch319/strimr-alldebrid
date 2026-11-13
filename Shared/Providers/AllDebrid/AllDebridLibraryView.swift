import SwiftUI
import AVKit
import Security

/// Independent, experimental AllDebrid library. It does not impersonate a Plex server.
struct AllDebridLibraryView: View {
    @State private var apiKey = ""
    @State private var links: [AllDebridSavedLink] = []
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
                            Text("Your key is saved in the iOS Keychain, not in the project files. This experimental screen reads saved links; magnet history is not supported yet.")
                                .font(.footnote)
                        }
                    }
                } else {
                    List {
                        if links.isEmpty && !isLoading {
                            ContentUnavailableView("No video links found", systemImage: "film", description: Text("Saved links may be empty. Magnet history is not supported in this version."))
                        }
                        ForEach(links.filter(\.isVideo)) { link in
                            Button {
                                Task { await play(link) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "film").foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(Self.cleanTitle(link.filename)).font(.headline)
                                        Text(link.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
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
                            AllDebridKeychain.delete()
                            apiKey = ""
                            links = []
                            isConfigured = false
                            playerURL = nil
                        }
                    }
                }
            }
            .overlay { if isLoading { ProgressView("Loading…") } }
            .alert("AllDebrid", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "Unknown error") }
            .sheet(isPresented: $showPlayer, onDismiss: { playerURL = nil }) {
                if let playerURL {
                    AllDebridVideoPlayer(url: playerURL)
                }
            }
            .task {
                if let key = AllDebridKeychain.load() {
                    apiKey = key
                    isConfigured = true
                    await refresh()
                }
            }
        }
    }

    private func connect() async {
        await refresh()
        if errorMessage == nil {
            guard AllDebridKeychain.save(apiKey) else {
                errorMessage = "Could not save your API key securely."
                return
            }
            isConfigured = true
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try AllDebridAPIClient(apiKey: apiKey)
            links = try await client.savedLinks().filter(\.isVideo)
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

    static func cleanTitle(_ filename: String) -> String {
        let basename = (filename as NSString).deletingPathExtension
        let separators = basename.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        let pattern = #"(?i)\b(2160p|1080p|720p|web[- ]?dl|bluray|remux|x265|h265|hevc|hdr10|dv|dovi)\b.*$"#
        let cleaned = separators.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AllDebridVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player { VideoPlayer(player: player).ignoresSafeArea() }
            else { ProgressView() }
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

private enum AllDebridKeychain {
    private static let service = "com.strimr.experimental.alldebrid"
    private static let account = "api-key"

    static func save(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
