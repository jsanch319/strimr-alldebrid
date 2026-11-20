import SwiftUI

/// Details remain discoverable when the optional Activity was not configured in the installed build.
struct DiscordWatchTogetherAction: View {
    let media: MediaItem
    var canLaunch = true
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if DiscordWatchTogetherConfiguration.isConfigured {
                Button(action: launch) { Label("Watch Together on Discord", systemImage: "person.2.wave.2") }
                    .buttonStyle(.bordered).disabled(!canLaunch)
                    .accessibilityIdentifier("discord.watch-together")
                if !canLaunch {
                    Text("Choose an episode to start Watch Together.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                DisclosureGroup("Discord Watch Together Setup") {
                    Text(DiscordWatchTogetherConfiguration.setupExplanation).font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("discord.setup")
                Text("Not configured in this build. A deployed Discord Activity is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert(
            "Discord Watch Together",
            isPresented: Binding(get: { message != nil }, set: {
                if !$0 {
                    message = nil
                }
            }),
        ) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func launch() {
        guard let url = DiscordWatchTogetherConfiguration.activityLaunchURL(
            for: media, position: media.viewOffset ?? 0, duration: media.duration,
        ) else { message = DiscordWatchTogetherConfiguration.setupExplanation; return }
        DiscordWatchTogetherConfiguration.openActivityURL(url) { result in
            switch result {
            case .opened: break // A successful URL handoff does not certify Activity deployment/synchronization.
            case .discordNotInstalled: message = "Install Discord to open this Activity."
            case .activityUnavailable: message = "Discord could not open the Activity. Verify its deployment and Discord URL mappings."
            }
        }
    }
}
