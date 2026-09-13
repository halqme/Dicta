import SwiftUI

struct ModelsSettingsPane: View {
    let environment: AppEnvironment

    var body: some View {
        @Bindable var settings = environment.settings
        let modelManagement = environment.modelManagement

        VStack(alignment: .leading, spacing: 14) {
            Form {
                ModelPickerRow(
                    title: "Preview model:",
                    selection: $settings.previewModelID,
                    options: settings.previewOptions,
                    selectedOption: settings.selectedPreviewOption,
                    role: .preview,
                    unavailableMessage: "No live preview is available for \(settings.language.displayName)."
                )

                ModelPickerRow(
                    title: "Final model:",
                    selection: $settings.finalModelID,
                    options: settings.finalOptions,
                    selectedOption: settings.selectedFinalOption,
                    role: .final,
                    unavailableMessage: "No final model is available for \(settings.language.displayName)."
                )

                if let activeID = modelManagement.activeOperationID,
                   activeID != "silero-vad",
                   let option = activeModel(id: activeID, settings: settings)
                {
                    LabeledContent("Status:") {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading \(option.name)…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.columns)

            Text("Changing a model downloads it automatically. Speed and accuracy are relative model ratings, not benchmark results.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .navigationTitle("Models")
    }

    private func activeModel(id: String, settings: SettingsStore) -> ASRModelOption? {
        settings.previewOptions.first(where: { $0.id == id })
            ?? settings.finalOptions.first(where: { $0.id == id })
    }
}

private struct ModelPickerRow: View {
    let title: String
    @Binding var selection: String
    let options: [ASRModelOption]
    let selectedOption: ASRModelOption?
    let role: ASRModelOption.Role
    let unavailableMessage: String

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 6) {
                if options.isEmpty {
                    Text(unavailableMessage)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $selection) {
                        ForEach(options) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320)

                    if let detail = selectedOption?.detail(for: role), !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let performance = selectedOption?.performance {
                        HStack(spacing: 16) {
                            ModelMetric(title: "Speed", value: performance.speedDisplayName)
                            ModelMetric(title: "Accuracy", value: performance.accuracyDisplayName)
                        }
                    }
                }
            }
            .frame(width: 330, alignment: .leading)
        }
    }
}

private struct ModelMetric: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
