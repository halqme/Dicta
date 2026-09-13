import SwiftUI

struct GeneralSettingsPane: View {
    let environment: AppEnvironment

    var body: some View {
        @Bindable var settings = environment.settings
        let modelManagement = environment.modelManagement

        Form {
            LabeledContent("Shortcut:") {
                ShortcutRecorderView(shortcut: $settings.hotKey)
                    .frame(width: 150, height: 28)
                    .disabled(environment.appModel.isRecording)
            }

            Picker("Activation:", selection: $settings.captureMode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .disabled(environment.appModel.isRecording)

            Picker("Language:", selection: $settings.language) {
                ForEach(InputLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .frame(width: 220)
            .disabled(environment.appModel.isRecording)

            Toggle("Finish after silence", isOn: $settings.silenceAutoFinish)
                .disabled(environment.appModel.isRecording || settings.captureMode == .pushToTalk)

            if settings.captureMode == .toggle && settings.silenceAutoFinish {
                LabeledContent("Silence duration:") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.silenceDuration, in: 0.5...5, step: 0.25)
                            .frame(width: 180)

                        Text(settings.silenceDuration, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)

                        Text("s")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(environment.appModel.isRecording)
            }

            if modelManagement.activeOperationID == "silero-vad" {
                LabeledContent("Speech detection:") {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(24)
        .navigationTitle("General")
        .onChange(of: settings.hotKey) {
            environment.registerCurrentHotKey()
        }
        .onChange(of: settings.captureMode) {
            if settings.captureMode == .toggle && settings.silenceAutoFinish {
                modelManagement.installVAD()
            }
        }
        .onChange(of: settings.silenceAutoFinish) {
            if settings.captureMode == .toggle && settings.silenceAutoFinish {
                modelManagement.installVAD()
            }
        }
    }
}
