import SwiftUI

struct LiveTranscriptView: View {
    let appModel: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: appModel.isRecording)

            Text(appModel.previewText.isEmpty ? "Listening…" : appModel.previewText)
                .lineLimit(2)
                .frame(maxWidth: 520, alignment: .leading)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
