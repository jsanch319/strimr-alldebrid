import SwiftUI

@MainActor
struct AuthorizedSourceSetupView: View {
    @AppStorage(AuthorizedSourceSettings.key) private var endpoints = ""
    @State private var draft = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("Authorized Source Providers") {
                Text(
                    "AllDebrid unlocks links and processes magnets; it does not search the movie catalog. Add HTTPS JSON search endpoints supplied by a provider you are authorized to use.",
                )
                .font(.footnote).foregroundStyle(.secondary)
                #if os(tvOS)
                    TextField("HTTPS provider endpoint", text: $draft).autocorrectionDisabled()
                #else
                    TextEditor(text: $draft).frame(minHeight: 100).autocorrectionDisabled()
                #endif
                Button("Save Providers") {
                    let lines = draft.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    guard lines.count <= 5,
                          lines.allSatisfy({ HTTPSAuthorizedSourceProvider.endpoint($0) != nil })
                    else {
                        message = "Enter up to five HTTPS endpoint URLs, one per line, without passwords, query tokens or fragments."
                        return
                    }
                    endpoints = lines.joined(separator: "\n")
                    message = lines
                        .isEmpty ?
                        "No automatic provider configured. You can still add authorized links from title details." : "Providers saved. Retry playback to search them."
                }
                if let message {
                    Text(message).font(.footnote)
                }
            } footer: {
                Text(
                    "Saving enables automatic submission of matching links to your connected AllDebrid account. Use only providers and files you have permission to access. No providers are bundled.",
                )
            }
            Section("Provider Format") {
                Text(
                    "GET parameters: tmdb_id, kind (movie/tv), title, year, and for episodes season and episode. Return a JSON array containing tmdbID, kind, year, season, episode, filename, link and authorized: true. Link must be a magnet URI or a download URL. Files must identify the correct title, year and episode. See Docs/AuthorizedSources.md for the full contract.",
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Playback Sources")
        .onAppear { draft = endpoints }
    }
}
