import SwiftUI

@MainActor
struct SettingsAudioView: View {
    @Environment(SettingsManager.self) private var settingsManager

    private var viewModel: SettingsViewModel {
        SettingsViewModel(settingsManager: settingsManager)
    }

    var body: some View {
        List {
            #if os(iOS)
                Section {
                    Toggle("Always Prefer English Audio", isOn: Binding(
                        get: { settingsManager.playback.alwaysPreferEnglishAudio },
                        set: { value in settingsManager.updatePlayback { $0.alwaysPreferEnglishAudio = value } },
                    ))
                } footer: {
                    Text(
                        "Prefer main English audio using real track language metadata. Manual choices override this preference for the current playback. If English is missing, another ready source is used only when its audio can be verified; otherwise playback continues with a notice.",
                    )
                }
            #endif
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("settings.playback.losslessAudio", isOn: viewModel.losslessAudioBinding)
                    Text("settings.playback.losslessAudio.footer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if viewModel.isSpatialAudioAvailable {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("settings.playback.spatialAudio", isOn: viewModel.spatialAudioBinding)
                        Text("settings.playback.spatialAudio.footer")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "settings.playback.rememberTrackSelections",
                        isOn: viewModel.rememberTrackSelectionsBinding,
                    )
                    Text("settings.playback.rememberTrackSelections.footer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("settings.playback.audio.title")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("settings.playback.nightMode", isOn: viewModel.nightModeBinding)
                    Text("settings.playback.nightMode.footer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("settings.playback.dialogueBoost", selection: viewModel.dialogueBoostBinding) {
                        ForEach(DialogueBoost.allCases) { boost in
                            Text(boost.title).tag(boost)
                        }
                    }
                    Text("settings.playback.dialogueBoost.footer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("settings.playback.audioEnhancements")
            } footer: {
                Text("settings.playback.audioEnhancements.footer")
            }

            Section {
                AudioDelaySettingsRow()
            } footer: {
                Text("settings.playback.audioDelay.footer")
            }
        }
        .insetListStyle()
        .navigationTitle("settings.playback.audio.title")
    }
}
