import ApplicationServices
import CoreGraphics
import SwiftUI

struct PrivacySettingsPane: View {
    let environment: AppEnvironment

    @Environment(\.scenePhase) private var scenePhase
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var postEventGranted = CGPreflightPostEventAccess()
    @State private var confirmingHistoryClear = false

    var body: some View {
        @Bindable var settings = environment.settings

        VStack(alignment: .leading, spacing: 14) {
            Form {
                PermissionRow(
                    title: "Accessibility:",
                    granted: accessibilityGranted,
                    detail: "Lets Dicta identify the focused text field and insert the final transcript directly.",
                    requestAction: requestAccessibility
                )

                PermissionRow(
                    title: "Paste fallback:",
                    granted: postEventGranted,
                    detail: "Lets Dicta synthesize Command-V when direct Accessibility insertion isn't available.",
                    requestAction: requestPostEventAccess
                )

                Toggle("Keep transcript history", isOn: $settings.keepHistory)

                LabeledContent("Stored history:") {
                    Text("Up to 100 transcripts for 7 days")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("") {
                    Button("Clear History…", role: .destructive) {
                        confirmingHistoryClear = true
                    }
                    .disabled(environment.appModel.history.isEmpty)
                }
            }
            .formStyle(.columns)

            Text("Microphone access is requested by macOS on first recording. Recorded audio is never persisted.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .navigationTitle("Privacy")
        .onAppear(perform: refreshPermissions)
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                refreshPermissions()
            }
        }
        .alert("Clear Transcript History?", isPresented: $confirmingHistoryClear) {
            Button("Clear History", role: .destructive) {
                environment.controller.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes Dicta's saved transcript history. Recorded audio is not stored.")
        }
    }

    private func requestAccessibility() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
    }

    private func requestPostEventAccess() {
        postEventGranted = CGRequestPostEventAccess() || CGPreflightPostEventAccess()
    }

    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        postEventGranted = CGPreflightPostEventAccess()
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let detail: String
    let requestAction: () -> Void

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Label(
                        granted ? "Allowed" : "Not allowed",
                        systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle"
                    )

                    Spacer(minLength: 12)

                    if !granted {
                        Button("Request Access…", action: requestAction)
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 340, alignment: .leading)
        }
    }
}
