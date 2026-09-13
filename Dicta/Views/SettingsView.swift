import ApplicationServices
import CoreGraphics
import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var postEventGranted = CGPreflightPostEventAccess()

    var body: some View {
        @Bindable var settings = environment.settings
        let modelManagement = environment.modelManagement

        Form {
            Section("Activation") {
                LabeledContent("Shortcut") {
                    ShortcutRecorderView(shortcut: $settings.hotKey)
                        .frame(width: 150, height: 28)
                        .disabled(environment.appModel.isRecording)
                }

                Picker("Mode", selection: $settings.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(environment.appModel.isRecording)

                Text("Push to Talk finishes on key release. Toggle finishes on the next press or, optionally, after silence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Input") {
                Picker("Language", selection: $settings.language) {
                    ForEach(InputLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(environment.appModel.isRecording)

                Toggle("Finish after silence", isOn: $settings.silenceAutoFinish)
                    .disabled(environment.appModel.isRecording || settings.captureMode == .pushToTalk)

                LabeledContent("Silence duration") {
                    HStack {
                        Slider(value: $settings.silenceDuration, in: 0.5...5, step: 0.25)
                            .frame(width: 180)
                        Text(settings.silenceDuration, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                        Text("s")
                    }
                }
                .disabled(environment.appModel.isRecording || settings.captureMode == .pushToTalk || !settings.silenceAutoFinish)

                if settings.captureMode == .toggle && settings.silenceAutoFinish {
                    Button(modelManagement.activeOperationID == "silero-vad" ? "Installing Speech Detector…" : "Install Speech Detector") {
                        modelManagement.installVAD()
                    }
                    .disabled(environment.appModel.isRecording || modelManagement.activeOperationID != nil)
                }
            }

            Section("Models") {
                if settings.previewOptions.isEmpty {
                    LabeledContent("Preview") {
                        Text("Unavailable for \(settings.language.displayName)")
                            .foregroundStyle(.secondary)
                    }
                    Text("Dicta only offers small always-resident models for live preview. No compatible preview model is currently available for this language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Preview", selection: $settings.previewModelID) {
                        ForEach(settings.previewOptions) { option in
                            Text(modelPickerLabel(option)).tag(option.id)
                        }
                    }
                    .disabled(environment.appModel.isRecording)
                    LabeledContent {
                        Button(modelManagement.activeOperationID == settings.previewModelID ? "Installing…" : "Install Preview Model") {
                            modelManagement.installPreview(modelID: settings.previewModelID)
                        }
                        .disabled(environment.appModel.isRecording || modelManagement.activeOperationID != nil || settings.previewModelID.isEmpty)
                    } label: {
                        ModelDescriptionView(
                            option: settings.selectedPreviewOption,
                            role: .preview
                        )
                    }
                }

                Picker("Final", selection: $settings.finalModelID) {
                    ForEach(settings.finalOptions) { option in
                        Text(modelPickerLabel(option)).tag(option.id)
                    }
                }
                .disabled(environment.appModel.isRecording)

                LabeledContent {
                    Button(modelManagement.activeOperationID == settings.finalModelID ? "Installing…" : "Install Final Model") {
                        modelManagement.installFinal(modelID: settings.finalModelID)
                    }
                    .disabled(environment.appModel.isRecording || modelManagement.activeOperationID != nil || settings.finalModelID.isEmpty)
                } label: {
                    ModelDescriptionView(
                        option: settings.selectedFinalOption,
                        role: .final
                    )
                }

                if let status = modelManagement.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Model downloads happen here. Starting a dictation only loads models already present in FluidAudio’s local cache. Speed and accuracy are coarse relative ratings, not cross-hardware benchmark scores.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    Label(
                        accessibilityGranted ? "Granted" : "Required",
                        systemImage: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(accessibilityGranted ? .primary : .secondary)
                }

                HStack {
                    Button("Request Accessibility Access") {
                        let options = [
                            "AXTrustedCheckOptionPrompt": true
                        ] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                        accessibilityGranted = AXIsProcessTrusted()
                    }
                    Button("Refresh") {
                        accessibilityGranted = AXIsProcessTrusted()
                        postEventGranted = CGPreflightPostEventAccess()
                    }
                }

                LabeledContent("Paste Automation") {
                    Label(
                        postEventGranted ? "Granted" : "Required for fallback",
                        systemImage: postEventGranted ? "checkmark.circle.fill" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(postEventGranted ? .primary : .secondary)
                }

                Button("Request Paste Automation Access") {
                    postEventGranted = CGRequestPostEventAccess() || CGPreflightPostEventAccess()
                }

                Text("Accessibility captures and edits supported text fields. Paste Automation is used only for the clipboard-preserving Cmd-V fallback. Microphone permission is requested by macOS on first recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Toggle("Keep local transcript history", isOn: $settings.keepHistory)
                Text("Keeps the newest 100 items and removes items older than 7 days. Recorded audio is never persisted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear History", role: .destructive) {
                    environment.controller.clearHistory()
                }
                .disabled(environment.appModel.history.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .padding()
        .onChange(of: settings.hotKey) {
            environment.registerCurrentHotKey()
        }
        .onChange(of: settings.previewModelID) {
            if !settings.previewModelID.isEmpty {
                modelManagement.installPreview(modelID: settings.previewModelID)
            }
        }
        .onChange(of: settings.finalModelID) {
            if !settings.finalModelID.isEmpty {
                modelManagement.installFinal(modelID: settings.finalModelID)
            }
        }
        .onAppear {
            environment.windowPresenter.settingsDidAppear()
            accessibilityGranted = AXIsProcessTrusted()
            postEventGranted = CGPreflightPostEventAccess()
        }
    }

    private func modelPickerLabel(_ option: ASRModelOption) -> String {
        guard let performance = option.performance else { return option.name }
        return "\(option.name) · \(performance.speedDisplayName) · \(performance.accuracyDisplayName) accuracy"
    }
}

private struct ModelDescriptionView: View {
    let option: ASRModelOption?
    let role: ASRModelOption.Role

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let detail = option?.detail(for: role), !detail.isEmpty {
                Text(detail)
            }
            if let performance = option?.performance {
                Text(performance.summary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
