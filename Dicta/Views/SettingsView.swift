import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment

    @AppStorage("settings.selectedPane")
    private var selectedPane = SettingsPane.general

    var body: some View {
        @Bindable var settings = environment.settings
        let modelManagement = environment.modelManagement

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
        }
    }
}

private enum SettingsPane: String, Hashable {
    case general
    case models
    case privacy
}
