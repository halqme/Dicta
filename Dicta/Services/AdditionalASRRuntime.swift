import Foundation
import FluidAudio

/// Common boundary for FluidAudio ASR managers that do not conform to Dicta's existing
/// Parakeet/Cohere/Streaming manager shapes.
protocol FinalASRRuntime: Actor {
    func transcribe(samples: [Float], language: InputLanguage) async throws -> String
    func cleanup() async
}

actor SenseVoiceFinalRuntime: FinalASRRuntime {
    private let manager: SenseVoiceManager

    init(manager: SenseVoiceManager) {
        self.manager = manager
    }

    func transcribe(samples: [Float], language: InputLanguage) async throws -> String {
        // SenseVoice's public high-level manager defaults to language auto-detection. Dicta still
        // filters the model by its catalog languages before this point.
        try await manager.transcribe(audio: samples)
    }

    func cleanup() async {
        // SenseVoiceManager exposes no explicit cleanup API. Releasing this runtime releases the
        // manager and its Core ML model references.
    }
}

actor ParaformerFinalRuntime: FinalASRRuntime {
    private let manager: ParaformerManager

    init(manager: ParaformerManager) {
        self.manager = manager
    }

    func transcribe(samples: [Float], language: InputLanguage) async throws -> String {
        try await manager.transcribe(audio: samples)
    }

    func cleanup() async {
        // ParaformerManager exposes no explicit cleanup API. Releasing this runtime releases the
        // manager and its Core ML model references.
    }
}

actor NemotronMultilingualFinalRuntime: FinalASRRuntime {
    private let manager: StreamingNemotronMultilingualAsrManager

    init(manager: StreamingNemotronMultilingualAsrManager) {
        self.manager = manager
    }

    func transcribe(samples: [Float], language: InputLanguage) async throws -> String {
        await manager.reset()
        await manager.setLanguage(language.nemotronMultilingualLanguageCode)

        do {
            _ = try await manager.process(samples: samples)
            let text = try await manager.finish()
            await manager.reset()
            return text
        } catch {
            await manager.reset()
            throw error
        }
    }

    func cleanup() async {
        await manager.cleanup()
    }
}

private extension InputLanguage {
    var nemotronMultilingualLanguageCode: String {
        switch self {
        case .english: "en-US"
        case .japanese: "ja-JP"
        case .chinese: "zh-CN"
        case .automatic: "auto"
        }
    }
}

/// Installation and local-only loading for FluidAudio's standalone ASR managers that sit outside
/// `AsrManager`, `CoherePipeline`, and `StreamingAsrManager`.
enum AdditionalASRAdapter {
    static let supportedBackendKinds: Set<String> = [
        "sensevoice",
        "paraformer",
        "nemotron-multilingual",
    ]

    static func install(_ option: ASRModelOption) async throws {
        switch option.backend.kind.rawValue {
        case "sensevoice":
            _ = try await SenseVoiceModels.download(precision: senseVoicePrecision(for: option))

        case "paraformer":
            _ = try await ParaformerModels.download(precision: paraformerPrecision(for: option))

        case "nemotron-multilingual":
            _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: "multilingual",
                chunkMs: try nemotronChunkMilliseconds(for: option)
            )

        default:
            throw ASRServiceError.unsupportedFinalModel(modelID: option.id)
        }
    }

    static func preflight(_ option: ASRModelOption) throws {
        switch option.backend.kind.rawValue {
        case "sensevoice":
            let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .senseVoiceSmall)
            guard SenseVoiceModels.modelsExist(
                at: directory,
                precision: senseVoicePrecision(for: option)
            ) else {
                throw ASRServiceError.modelNotInstalled(modelID: option.id)
            }

        case "paraformer":
            let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .paraformerLargeZh)
            guard ParaformerModels.modelsExist(
                at: directory,
                precision: paraformerPrecision(for: option)
            ) else {
                throw ASRServiceError.modelNotInstalled(modelID: option.id)
            }

        case "nemotron-multilingual":
            let directory = nemotronMultilingualDirectory(
                chunkMs: try nemotronChunkMilliseconds(for: option)
            )
            guard nemotronMultilingualFilesAreComplete(at: directory) else {
                throw ASRServiceError.modelNotInstalled(modelID: option.id)
            }

        default:
            throw ASRServiceError.unsupportedFinalModel(modelID: option.id)
        }
    }

    static func load(_ option: ASRModelOption) async throws -> any FinalASRRuntime {
        try preflight(option)

        do {
            switch option.backend.kind.rawValue {
            case "sensevoice":
                let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .senseVoiceSmall)
                let models = try SenseVoiceModels.load(
                    from: directory,
                    precision: senseVoicePrecision(for: option)
                )
                return SenseVoiceFinalRuntime(manager: SenseVoiceManager(models: models))

            case "paraformer":
                let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .paraformerLargeZh)
                let models = try ParaformerModels.load(
                    from: directory,
                    precision: paraformerPrecision(for: option)
                )
                return ParaformerFinalRuntime(manager: ParaformerManager(models: models))

            case "nemotron-multilingual":
                let directory = nemotronMultilingualDirectory(
                    chunkMs: try nemotronChunkMilliseconds(for: option)
                )
                let manager = StreamingNemotronMultilingualAsrManager()
                try await manager.loadModels(from: directory)
                return NemotronMultilingualFinalRuntime(manager: manager)

            default:
                throw ASRServiceError.unsupportedFinalModel(modelID: option.id)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ASRServiceError {
            throw error
        } catch {
            throw ASRServiceError.modelNotInstalled(modelID: option.id)
        }
    }

    static func isInstalled(_ option: ASRModelOption) -> Bool {
        switch option.backend.kind.rawValue {
        case "sensevoice":
            let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .senseVoiceSmall)
            return SenseVoiceModels.modelsExist(
                at: directory,
                precision: senseVoicePrecision(for: option)
            )

        case "paraformer":
            let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .paraformerLargeZh)
            return ParaformerModels.modelsExist(
                at: directory,
                precision: paraformerPrecision(for: option)
            )

        case "nemotron-multilingual":
            guard let chunkMs = try? nemotronChunkMilliseconds(for: option) else { return false }
            return nemotronMultilingualFilesAreComplete(
                at: nemotronMultilingualDirectory(chunkMs: chunkMs)
            )

        default:
            return false
        }
    }

    static func storageDirectory(for option: ASRModelOption) -> URL? {
        switch option.backend.kind.rawValue {
        case "sensevoice":
            MLModelConfigurationUtils.defaultModelsDirectory(for: .senseVoiceSmall)
        case "paraformer":
            MLModelConfigurationUtils.defaultModelsDirectory(for: .paraformerLargeZh)
        case "nemotron-multilingual":
            guard let chunkMs = try? nemotronChunkMilliseconds(for: option) else { return nil }
            return nemotronMultilingualDirectory(chunkMs: chunkMs)
        default:
            return nil
        }
    }

    private static func senseVoicePrecision(for option: ASRModelOption) -> SenseVoiceEncoderPrecision {
        switch option.backend.variantID {
        case "int8": .int8
        case "fp32": .fp32
        default: .fp16
        }
    }

    private static func paraformerPrecision(for option: ASRModelOption) -> ParaformerPrecision {
        option.backend.variantID == "int8" ? .int8 : .fp16
    }

    private static func nemotronChunkMilliseconds(for option: ASRModelOption) throws -> Int {
        guard let raw = option.backend.variantID else {
            throw ASRServiceError.unsupportedFinalModel(modelID: option.id)
        }
        let numeric = raw.hasSuffix("ms") ? String(raw.dropLast(2)) : raw
        guard let value = Int(numeric), [560, 1120, 2240, 4480].contains(value) else {
            throw ASRServiceError.unsupportedFinalModel(modelID: option.id)
        }
        return value
    }

    private static func nemotronMultilingualDirectory(chunkMs: Int) -> URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotronMultilingual)
            .appendingPathComponent("multilingual", isDirectory: true)
            .appendingPathComponent("\(chunkMs)ms", isDirectory: true)
    }

    private static func nemotronMultilingualFilesAreComplete(at directory: URL) -> Bool {
        let fm = FileManager.default

        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }

        func modelExists(compiled: String, package: String) -> Bool {
            exists(compiled) || exists(package)
        }

        guard exists(ModelNames.NemotronMultilingualStreaming.metadata),
              exists(ModelNames.NemotronMultilingualStreaming.tokenizer),
              modelExists(
                  compiled: ModelNames.NemotronMultilingualStreaming.encoderFile,
                  package: ModelNames.NemotronMultilingualStreaming.encoderPackage
              )
        else { return false }

        let hasBareDecode = modelExists(
            compiled: ModelNames.NemotronMultilingualStreaming.decoderFile,
            package: ModelNames.NemotronMultilingualStreaming.decoderPackage
        ) && modelExists(
            compiled: ModelNames.NemotronMultilingualStreaming.jointFile,
            package: ModelNames.NemotronMultilingualStreaming.jointPackage
        )

        let hasFusedDecode = [
            "decoder_joint_argmax.mlmodelc",
            "decoder_joint_argmax.mlpackage",
            "decoder_joint_noencproj.mlmodelc",
            "decoder_joint_noencproj.mlpackage",
            "decoder_joint.mlmodelc",
            "decoder_joint.mlpackage",
        ].contains(where: exists)

        return hasBareDecode || hasFusedDecode
    }
}
