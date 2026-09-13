import SwiftUI

struct ModelsSettingsPane: View {
    let environment: AppEnvironment

    @State private var pendingRemoval: ASRModelOption?

    var body: some View {
        @Bindable var settings = environment.settings
        let modelManagement = environment.modelManagement

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech Models")
                        .font(.title2.weight(.semibold))
                    Text("Choose which models Dicta uses and manage their downloaded files.")
                        .foregroundStyle(.secondary)
                }

                ModelLibrarySection(
                    title: "Live Preview",
                    subtitle: "Shown while you speak. Preview text is never inserted.",
                    role: .preview,
                    options: settings.previewOptions,
                    selectedID: settings.previewModelID,
                    modelManagement: modelManagement,
                    unavailableMessage: "No live preview model is available for \(settings.language.displayName).",
                    select: { settings.previewModelID = $0.id },
                    download: { modelManagement.installPreview(modelID: $0.id) },
                    requestRemoval: { pendingRemoval = $0 },
                    canRemove: { option in
                        option.id != settings.previewModelID && option.id != settings.finalModelID
                    }
                )

                ModelLibrarySection(
                    title: "Final Transcription",
                    subtitle: "Used after recording finishes. Only this result can be inserted.",
                    role: .final,
                    options: settings.finalOptions,
                    selectedID: settings.finalModelID,
                    modelManagement: modelManagement,
                    unavailableMessage: "No final model is available for \(settings.language.displayName).",
                    select: { settings.finalModelID = $0.id },
                    download: { modelManagement.installFinal(modelID: $0.id) },
                    requestRemoval: { pendingRemoval = $0 },
                    canRemove: { option in
                        option.id != settings.previewModelID && option.id != settings.finalModelID
                    }
                )

                Text("Selecting a model does not download it. Downloaded models remain on this Mac until you remove them. Speed and accuracy are relative ratings, not cross-hardware benchmark scores.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .frame(minHeight: 520)
        .navigationTitle("Models")
        .task {
            await modelManagement.refreshInstalledModels()
        }
        .alert(
            "Remove Downloaded Model?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { option in
            Button("Remove", role: .destructive) {
                modelManagement.removeModel(modelID: option.id)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { option in
            Text("Remove \(option.name) from this Mac? You can download it again later.")
        }
    }
}

private struct ModelLibrarySection: View {
    let title: String
    let subtitle: String
    let role: ASRModelOption.Role
    let options: [ASRModelOption]
    let selectedID: String
    let modelManagement: ModelManagementModel
    let unavailableMessage: String
    let select: (ASRModelOption) -> Void
    let download: (ASRModelOption) -> Void
    let requestRemoval: (ASRModelOption) -> Void
    let canRemove: (ASRModelOption) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                if options.isEmpty {
                    Text(unavailableMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            ModelLibraryRow(
                                option: option,
                                role: role,
                                selected: option.id == selectedID,
                                installed: modelManagement.isInstalled(modelID: option.id),
                                active: modelManagement.activeOperationID == option.id,
                                canRemove: canRemove(option),
                                select: { select(option) },
                                download: { download(option) },
                                requestRemoval: { requestRemoval(option) }
                            )

                            if index < options.count - 1 {
                                Divider()
                                    .padding(.leading, 38)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ModelLibraryRow: View {
    let option: ASRModelOption
    let role: ASRModelOption.Role
    let selected: Bool
    let installed: Bool
    let active: Bool
    let canRemove: Bool
    let select: () -> Void
    let download: () -> Void
    let requestRemoval: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: select) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(selected ? "Selected" : "Use this model")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(option.name)
                        .fontWeight(.medium)

                    if selected {
                        Text("Selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let detail = option.detail(for: role), !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let performance = option.performance {
                    HStack(spacing: 14) {
                        Text("Speed: \(performance.speedDisplayName)")
                        Text("Accuracy: \(performance.accuracyDisplayName)")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 6) {
                if active {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(
                        installed ? "Downloaded" : "Not downloaded",
                        systemImage: installed ? "checkmark.circle" : "icloud.and.arrow.down"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if installed {
                        if canRemove {
                            Button("Remove…", role: .destructive, action: requestRemoval)
                                .controlSize(.small)
                        } else {
                            Text("In Use")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Download", action: download)
                            .controlSize(.small)
                    }
                }
            }
            .frame(minWidth: 112, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
