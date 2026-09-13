import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment

    @AppStorage("settings.selectedPane")
    private var selectedPane = SettingsPane.general

    var body: some View {
        TabView(selection: $selectedPane) {
            GeneralSettingsPane(environment: environment)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsPane.general)

            ModelsSettingsPane(environment: environment)
                .tabItem {
                    Label("Models", systemImage: "waveform")
                }
                .tag(SettingsPane.models)

            PrivacySettingsPane(environment: environment)
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }
                .tag(SettingsPane.privacy)
        }
        .frame(width: 540)
        .onAppear {
            environment.windowPresenter.settingsDidAppear()
        }
    }
}

private enum SettingsPane: String, Hashable {
    case general
    case models
    case privacy
}
