import SwiftUI

struct FallbackEditorView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $appModel.fallbackText)
                .font(.body)
                .padding(8)
                .writingToolsBehavior(.complete)
                .writingToolsAffordanceVisibility(.visible)

            Divider()

            HStack {
                Text("Uninserted dictations are appended here in FIFO order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Clear") {
                    appModel.clearFallbackText()
                }
                .disabled(appModel.fallbackText.isEmpty)

                Button("Copy") {
                    appModel.copyFallbackText()
                }
                .disabled(appModel.fallbackText.isEmpty)
            }
            .padding(10)
        }
    }
}
