import AppKit
import SwiftUI

struct MenuBarView: View {
    let environment: AppEnvironment
    @Environment(\.openSettings) private var openSettingsAction

    private var appModel: AppModel { environment.appModel }

    var body: some View {
        Button(appModel.isRecording ? "Stop Dictation" : "Start Dictation") {
            environment.controller.toggleFromMenu()
        }

        if appModel.isRecording {
            Button("Cancel Dictation", role: .destructive) {
                environment.controller.cancelCurrent()
            }
        }

        if appModel.queuedFinalizations > 0 {
            Text("Finalizing \(appModel.queuedFinalizations)…")
        }

        if let error = appModel.lastErrorMessage {
            Divider()
            Text(error)
            Button("Dismiss Error") {
                appModel.clearError()
            }
        }

        Divider()

        Button("Fallback Editor") {
            environment.controller.showFallbackEditor()
        }

        if !appModel.history.isEmpty {
            Menu("Recent Dictations") {
                ForEach(appModel.history.prefix(8)) { item in
                    Button(Self.menuTitle(for: item.text)) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(item.text, forType: .string)
                    }
                }
            }
        }

        Button("Settings…") {
            environment.windowPresenter.showSettings {
                openSettingsAction()
            }
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private static func menuTitle(for text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 30 { return singleLine }
        return String(singleLine.prefix(27)) + "…"
    }
}
