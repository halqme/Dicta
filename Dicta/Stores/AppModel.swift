import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var isRecording = false
    private(set) var queuedFinalizations = 0
    private(set) var history: [TranscriptHistoryItem] = []
    var previewText = ""
    var fallbackText = ""
    var lastErrorMessage: String?

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        previewText = ""
        lastErrorMessage = nil
    }

    func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        previewText = ""
    }

    func cancelRecording() {
        isRecording = false
        previewText = ""
    }

    func setQueuedFinalizations(_ count: Int) {
        queuedFinalizations = max(0, count)
    }

    func setHistory(_ items: [TranscriptHistoryItem]) {
        history = HistoryRetention.prune(items)
    }

    func report(_ error: Error) {
        lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func report(message: String) {
        lastErrorMessage = message
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func appendFallback(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if fallbackText.isEmpty {
            fallbackText = normalized
        } else {
            fallbackText += "\n\n" + normalized
        }
    }

    func copyFallbackText() {
        guard !fallbackText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fallbackText, forType: .string)
    }

    func clearFallbackText() {
        fallbackText = ""
    }
}
