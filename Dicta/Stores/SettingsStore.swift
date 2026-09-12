import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let captureMode = "captureMode"
        static let language = "language"
        static let previewModelID = "previewModelID"
        static let finalModelID = "finalModelID"
        static let silenceAutoFinish = "silenceAutoFinish"
        static let silenceDuration = "silenceDuration"
        static let keepHistory = "keepHistory"
        static let hotKey = "hotKey"
    }

    private let defaults: UserDefaults
    private let modelCatalog: ModelCatalog

    var captureMode: CaptureMode { didSet { defaults.set(captureMode.rawValue, forKey: Key.captureMode) } }
    var language: InputLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            normalizeModelsForLanguage()
        }
    }
    var previewModelID: String { didSet { defaults.set(previewModelID, forKey: Key.previewModelID) } }
    var finalModelID: String { didSet { defaults.set(finalModelID, forKey: Key.finalModelID) } }
    var silenceAutoFinish: Bool { didSet { defaults.set(silenceAutoFinish, forKey: Key.silenceAutoFinish) } }
    var silenceDuration: Double { didSet { defaults.set(silenceDuration, forKey: Key.silenceDuration) } }
    var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: Key.keepHistory) } }
    var hotKey: HotKeyConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(hotKey) {
                defaults.set(data, forKey: Key.hotKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard, modelCatalog: ModelCatalog = .builtIn) {
        self.defaults = defaults
        self.modelCatalog = modelCatalog

        captureMode = defaults.string(forKey: Key.captureMode)
            .flatMap(CaptureMode.init(rawValue:)) ?? .toggle
        language = defaults.string(forKey: Key.language)
            .flatMap(InputLanguage.init(rawValue:)) ?? .japanese
        previewModelID = defaults.string(forKey: Key.previewModelID) ?? ""
        finalModelID = defaults.string(forKey: Key.finalModelID) ?? ""
        silenceAutoFinish = defaults.object(forKey: Key.silenceAutoFinish) as? Bool ?? true
        silenceDuration = defaults.object(forKey: Key.silenceDuration) as? Double ?? 1.5
        keepHistory = defaults.object(forKey: Key.keepHistory) as? Bool ?? true
        hotKey = defaults.data(forKey: Key.hotKey)
            .flatMap { try? JSONDecoder().decode(HotKeyConfiguration.self, from: $0) }
            ?? .optionSpace

        if language == .automatic {
            language = .japanese
        }
        normalizeModelsForLanguage()
    }

    var previewOptions: [ASRModelOption] {
        modelCatalog.previewOptions(for: language)
    }

    var finalOptions: [ASRModelOption] {
        modelCatalog.finalOptions(for: language)
    }

    var selectedPreviewOption: ASRModelOption? {
        modelCatalog.previewOption(id: previewModelID)
    }

    var selectedFinalOption: ASRModelOption? {
        modelCatalog.finalOption(id: finalModelID)
    }

    var hasPreviewForCurrentLanguage: Bool {
        !previewOptions.isEmpty
    }

    private func normalizeModelsForLanguage() {
        let previews = modelCatalog.previewOptions(for: language)
        if previews.isEmpty {
            if !previewModelID.isEmpty {
                previewModelID = ""
            }
        } else if !previews.contains(where: { $0.id == previewModelID }) {
            previewModelID = modelCatalog.defaultPreviewOption(for: language)?.id ?? ""
        }

        let finals = modelCatalog.finalOptions(for: language)
        if !finals.contains(where: { $0.id == finalModelID }) {
            finalModelID = modelCatalog.defaultFinalOption(for: language)?.id ?? ""
        }
    }
}
