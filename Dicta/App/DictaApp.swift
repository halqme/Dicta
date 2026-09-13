import AppKit
import SwiftUI

@main
@MainActor
struct DictaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra(
            "Dicta",
            systemImage: environment.appModel.isRecording ? "waveform.circle.fill" : "waveform.circle"
        ) {
            MenuBarView(environment: environment)
        }

        Settings {
            SettingsView(environment: environment)
                .onDisappear {
                    environment.windowPresenter.restoreAccessoryPolicyIfNeeded()
                }
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
