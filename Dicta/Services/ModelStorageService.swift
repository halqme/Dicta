import Foundation
import FluidAudio

/// Inspects and removes FluidAudio model files without loading model weights.
///
/// Installation remains owned by `ASRService`; this service is the disk-management boundary used
/// by Settings so selection and local resource management stay separate concepts.
actor ModelStorageService {
    private let modelCatalog: ModelCatalog

    init(modelCatalog: ModelCatalog) {
        self.modelCatalog = modelCatalog
    }

    func installedModelIDs() -> Set<String> {
        Set(modelCatalog.models.compactMap { option in
            isInstalled(option) ? option.id : nil
        })
    }

    func removeModel(modelID: String) throws {
        guard let option = modelCatalog.model(id: modelID),
              let location = storageLocation(for: option)
        else { return }

        switch location {
        case .directory(let directory):
            try removeIfPresent(directory)

        case .unified(let directory, let uniqueEncoder):
            let otherUnifiedInstalled = modelCatalog.models.contains { candidate in
                guard candidate.id != option.id,
                      candidate.backend.kind == .streaming,
                      let variantID = candidate.backend.variantID,
                      let variant = StreamingModelVariant(rawValue: variantID),
                      variant.engineFamily == .parakeetUnified
                else { return false }
                return isInstalled(candidate)
            }

            if otherUnifiedInstalled {
                try removeIfPresent(directory.appendingPathComponent(uniqueEncoder))
            } else {
                try removeIfPresent(directory)
            }
        }
    }

    private func isInstalled(_ option: ASRModelOption) -> Bool {
        if AdditionalASRAdapter.supportedBackendKinds.contains(option.backend.kind.rawValue) {
            return AdditionalASRAdapter.isInstalled(option)
        }

        guard let location = storageLocation(for: option) else { return false }

        switch location {
        case .directory(let directory):
            if option.backend.kind == .parakeet,
               let version = parakeetVersion(from: option)
            {
                return AsrModels.modelsExist(at: directory, version: version)
            }

            let required = requiredFiles(for: option)
            return !required.isEmpty && required.allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }

        case .unified(let directory, _):
            let required = requiredFiles(for: option)
            return !required.isEmpty && required.allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        }
    }

    private enum StorageLocation {
        case directory(URL)
        case unified(directory: URL, uniqueEncoder: String)
    }

    private func storageLocation(for option: ASRModelOption) -> StorageLocation? {
        if let directory = AdditionalASRAdapter.storageDirectory(for: option) {
            return .directory(directory)
        }

        if option.backend.kind == .cohereTranscribe {
            return .directory(
                MLModelConfigurationUtils.defaultModelsDirectory(for: .cohereTranscribeCoreml)
            )
        }

        if option.backend.kind == .parakeet,
           let version = parakeetVersion(from: option)
        {
            return .directory(AsrModels.defaultCacheDirectory(for: version))
        }

        if option.backend.kind == .streaming,
           let variantID = option.backend.variantID,
           let variant = StreamingModelVariant(rawValue: variantID)
        {
            let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: variant.repo)
            if variant.engineFamily == .parakeetUnified {
                return .unified(
                    directory: directory,
                    uniqueEncoder: unifiedEncoderFile(for: variant)
                )
            }
            return .directory(directory)
        }

        return nil
    }

    private func requiredFiles(for option: ASRModelOption) -> Set<String> {
        if option.backend.kind == .cohereTranscribe {
            return ModelNames.CohereTranscribe.requiredModels
        }

        if option.backend.kind == .streaming,
           let variantID = option.backend.variantID,
           let variant = StreamingModelVariant(rawValue: variantID)
        {
            switch variant.engineFamily {
            case .parakeetEou:
                return ModelNames.ParakeetEOU.requiredModels

            case .nemotron:
                return [
                    ModelNames.NemotronStreaming.encoderInt8File,
                    ModelNames.NemotronStreaming.decoderFile,
                    ModelNames.NemotronStreaming.jointFile,
                    ModelNames.NemotronStreaming.tokenizer,
                ]

            case .parakeetUnified:
                return [
                    unifiedEncoderFile(for: variant),
                    ModelNames.ParakeetUnified.decoderFile,
                    ModelNames.ParakeetUnified.jointDecisionFile,
                    ModelNames.ParakeetUnified.vocab,
                ]
            }
        }

        return []
    }

    private func unifiedEncoderFile(for variant: StreamingModelVariant) -> String {
        if variant == .parakeetUnifiedOffline15s {
            return ModelNames.ParakeetUnified.offlineEncoderInt8File
        }

        let config = variant.unifiedConfig ?? UnifiedConfig()
        return ModelNames.ParakeetUnified.streamingEncoderFile(
            precision: .int8,
            contextSuffix: config.contextSuffix
        )
    }

    private func parakeetVersion(from option: ASRModelOption) -> AsrModelVersion? {
        guard option.backend.kind == .parakeet,
              let versionID = option.backend.variantID
        else { return nil }

        switch versionID {
        case "v2": return .v2
        case "v3": return .v3
        case "tdt-ctc-110m": return .tdtCtc110m
        case "tdt-ja": return .tdtJa
        default: return nil
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
