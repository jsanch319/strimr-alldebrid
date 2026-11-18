import SwiftUI

@MainActor
struct StremioAddonsView: View {
    @State private var draft = ""
    @State private var authorized = false
    @State private var status = "Checking secure configuration…"
    @State private var name: String?
    @State private var busy = false
    @State private var operation = Operation.check
    @State private var operationID = UUID()
    private let store = StremioConfigurationStore()
    private enum Operation: Equatable { case check, save, remove }

    var body: some View {
        Form {
            Section("Configured Add-on") {
                if let name {
                    Text(name).font(.headline)
                }
                HStack {
                    if busy {
                        ProgressView()
                    }; Text(status).font(.footnote)
                }
                Button("Test Connection") { schedule(.check) }.disabled(busy)
            }
            Section {
                SecureField("Paste manifest URL", text: $draft).autocorrectionDisabled()
                    .privacySensitive()
                Toggle("I am authorized to use this add-on and its sources", isOn: $authorized)
                Button("Validate and Save") { schedule(.save) }.disabled(busy || draft.isEmpty || !authorized)
                Text(
                    "Paste your personally configured HTTPS or stremio:// manifest URL, including your existing AllDebrid configuration if required. Configuration URLs are stored only in Keychain and are never displayed here after saving. Saving replaces the current add-on.",
                )
                .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Add or Replace") }
            Section {
                Button("Remove Add-on", role: .destructive) { schedule(.remove) }.disabled(busy)
                Text(
                    "Compatible hosted Stremio/Torrentio configurations need no separate server. Availability and format support vary. Protected, browser-only and header-dependent sources are not supported. Manual source selection remains available in title details.",
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Stremio Add-ons")
        .task(id: operationID) {
            busy = true
            defer { busy = false }
            do {
                switch operation {
                case .remove:
                    try store.delete(); name = nil; draft = ""; authorized = false; status = "No add-on configured."
                case .check, .save:
                    let next: StremioConfiguration? = if operation == .save {
                        try StremioConfiguration(
                            url: draft,
                            authorized: authorized,
                        )
                    } else {
                        try store.load()
                    }
                    guard let next else { name = nil; status = "No add-on configured."; return }
                    let manifest = try await StremioClient().manifest(next)
                    try Task.checkCancellation()
                    if operation == .save {
                        try store.save(next); draft = ""
                    }
                    name = next.safeName(manifest.name); status = "Connected · Stream discovery available."
                }
            } catch {
                if !error
                    .isCancellation
                {
                    status = (error as? StremioError)?.localizedDescription ?? (error as? KeychainError)?
                        .localizedDescription ?? StremioError.connection.localizedDescription
                }
            }
        }
        .onDisappear { draft = "" }
    }

    private func schedule(_ next: Operation) {
        operation = next; operationID = UUID()
    }
}
