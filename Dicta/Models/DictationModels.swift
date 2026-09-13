import Foundation

/// Immutable mono PCM handed from capture to finalization.
///
/// Samples are Float32 values at the recorded sample rate. Keeping the sample rate with the
/// payload lets the ASR boundary resample hardware input without retaining an AVAudioPCMBuffer.
nonisolated struct PCMRecording: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double

    init(samples: [Float], sampleRate: Double = 16_000) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    static let empty = PCMRecording(samples: [])
}

typealias CapturedAudio = PCMRecording

nonisolated struct DictationSession: Identifiable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let language: InputLanguage
    let finalModelID: String
    let target: DictationTarget
    let audio: PCMRecording?

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        language: InputLanguage,
        finalModelID: String,
        target: DictationTarget,
        audio: PCMRecording? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.language = language
        self.finalModelID = finalModelID
        self.target = target
        self.audio = audio
    }
}

nonisolated enum DictationTarget: Sendable, Equatable {
    /// A legacy target carrying only a PID is not enough for direct AX insertion.
    case accessibility(applicationPID: Int32)
    /// The capture ID is a handle into InputDeliveryService's actor-owned AX storage.
    case accessibilityCapture(applicationPID: Int32, captureID: UUID)
    /// The capture ID lets the delivery actor enforce non-AX overlap routing.
    case pasteboardCapture(applicationPID: Int32?, captureID: UUID)
    case pasteboardFallback(applicationPID: Int32?)
    case fallbackEditor

    var isAccessibilityBacked: Bool {
        switch self {
        case .accessibility, .accessibilityCapture:
            true
        case .pasteboardCapture, .pasteboardFallback, .fallbackEditor:
            false
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case pushToTalk
    case toggle

    var id: Self { self }

    var displayName: String {
        switch self {
        case .pushToTalk: "Push to Talk"
        case .toggle: "Toggle"
        }
    }
}

/// Languages Dicta itself currently exposes to users.
///
/// This intentionally remains a closed app capability. The model catalog uses the open
/// `ModelLanguageCode` type so it may describe additional languages without requiring an app
/// update or breaking an older Dicta binary.
nonisolated enum InputLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case japanese = "ja"
    case english = "en"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .japanese: "Japanese"
        case .english: "English"
        }
    }
}

struct TranscriptResult: Sendable, Equatable {
    let sessionID: UUID
    let text: String
    let completedAt: Date
}

nonisolated struct TranscriptHistoryItem: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let createdAt: Date
    let text: String
    let destination: Destination

    enum Destination: String, Sendable, Codable {
        case accessibility
        case pasteboard
        case fallbackEditor
    }
}


struct HotKeyConfiguration: Sendable, Equatable, Codable {
    let keyCode: UInt32
    let modifierFlagsRawValue: UInt
    let displayKey: String

    static let optionSpace = HotKeyConfiguration(
        keyCode: 49,
        modifierFlagsRawValue: 1 << 19,
        displayKey: "Space"
    )
}
