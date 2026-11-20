import SwiftUI

struct DiscordNativePairingView: View {
    @Environment(\.dismiss) private var dismiss
    let bridge: DiscordNativeBridge
    let connect: @MainActor (String) async -> Void
    @State private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Connect to your Discord Activity") {
                    Text(
                        "In the Activity, select Use my Strimr iPhone player. Copy its one-use code here. Your friend watches inside Discord; your private playback URL stays on this iPhone.",
                    )
                    TextField("Pairing code", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    Button(bridge.isConnecting ? "Connecting…" : "Connect") {
                        Task {
                            await connect(code.trimmingCharacters(in: .whitespacesAndNewlines)); if bridge
                                .isConnected
                            {
                                code = ""
                            }
                        }
                    }.disabled(bridge.isConnecting || bridge.isConnected || code.isEmpty)
                    if !bridge.message.isEmpty {
                        Text(bridge.message).font(.footnote)
                    }
                }
                if bridge.isConnected {
                    Button("Disconnect from Discord", role: .destructive) { bridge.disconnect() }
                }
                Section {
                    Text(
                        "The Activity and authorized browser video sources must be deployed first. Discord availability while switching apps or locking this iPhone requires device testing. SharePlay and Discord synchronization cannot run together.",
                    )
                    .font(.footnote)
                }
            }
            .navigationTitle("Discord Watch Together")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onDisappear {
            code = ""; if bridge.isConnecting {
                bridge.disconnect()
            }
        }
    }
}
