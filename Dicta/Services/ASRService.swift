@preconcurrency import AVFoundation
import Foundation
import FluidAudio

/// Errors raised before or during local ASR preparation/finalization.
enum ASRServiceError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedPreviewModel(modelID: String, supportedModelIDs: [String])
    case unsupportedFinalModel(modelID: String)
    case unsupportedLanguage(modelID: String, language: InputLanguage)
    case modelNotInstalled(modelID: String)
    case missingAudio
    case emptyAudio
    case emptyTranscript
    case invalidAudio
    case audioBufferCreationFailed
    case finalModelNotPrepared(modelID: String)
    case finalManagerUnavailable(modelID: String)
    case finalModelBusy
    case previewModelBusy

    var errorDescription: String? {
        switch self {
        case .unsupportedPreviewModel(let modelID, let supportedModelIDs):
            "Unsupported preview model ID '\(modelID)'. Supported IDs: \(supportedModelIDs.joined(separator: ", "))."
        case .unsupportedFinalModel(let modelID):
            "Unsupported final model ID '\(modelID)'."
        case .unsupportedLanguage(let modelID, let language):
            "The model '\(modelID)' does not support the selected language '\(language.rawValue)'."
        case .modelNotInstalled(let modelID):
            "The model '\(modelID)' is not installed. Install it from Settings before dictating."
        case .missingAudio:
            "The recording did not contain an audio payload."
        case .emptyAudio:
            "The recording contained no audio samples."
        case .emptyTranscript:
            "The speech recognizer returned no text."
        case .invalidAudio:
            "The recording contained an invalid audio sample rate or sample value."
        case .audioBufferCreationFailed:
            "The recording could not be converted to an ASR audio buffer."
        case .finalModelNotPrepared(let modelID):
            "The final ASR model '\(modelID)' is not ready."
        case .finalManagerUnavailable(let modelID):
            "The final ASR manager '\(modelID)' is unavailable."
        case .finalModelBusy:
            "The final ASR model is busy preparing or being released."
        case .previewModelBusy:
            "The preview ASR model cannot be changed during an active dictation."
        }
    }
}

private extension InputLanguage {
    var fluidAudioLanguage: Language? {
        switch self {
        case .english:
            .english
        case .japanese, .automatic:
            nil
        }
    }

    var cohereLanguage: CohereAsrConfig.Language? {
        switch self {
        case .japanese:
            .japanese
        case .english:
            .english
        case .automatic:
            nil
        }
    }
}

/// Boundary around FluidAudio. Model objects stay actor-isolated while immutable PCM recordings
/// cross from capture/finalization as Sendable values.
actor ASRService {
    static let finalModelIdleLifetime: Duration = .seconds(10 * 60)

    private let modelCatalog: ModelCatalog

    init(modelCatalog: ModelCatalog = .builtIn) {
        self.modelCatalog = modelCatalog
    }

    private enum LoadedFinalModel {
        case cohere(CoherePipeline, CoherePipeline.LoadedModels)
        case parakeet(AsrManager)
        case streaming(any StreamingAsrManager)
    }

    /// Backends currently implemented by the FluidAudio adapter. The catalog itself remains open
    /// to other backend identifiers and they fail as unsupported only when selected.
    private enum SupportedBackendKind: String {
        case cohereTranscribe = "cohere-transcribe"
        case parakeet
        case streaming
    }

    func installPreviewModel(modelID: String) async throws {
        guard activePreviewSessionModelID == nil else { throw ASRServiceError.previewModelBusy }
        guard let option = modelCatalog.previewOption(id: modelID),
              let variant = Self.streamingVariant(from: option)
        else {
            throw ASRServiceError.unsupportedPreviewModel(
                modelID: modelID,
                supportedModelIDs: modelCatalog.previewModels.map(\.id)
            )
        }

        let manager = variant.createManager()
        try await manager.loadModels()
        let previous = loadedPreviewModel
        loadedPreviewModel = manager
        loadedPreviewModelID = modelID
        if let previous { await previous.cleanup() }
    }

    func installFinalModel(modelID: String) async throws {
        guard let option = modelCatalog.finalOption(id: modelID) else {
            throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
        }
        guard let backendKind = Self.supportedBackendKind(from: option) else {
            throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
        }

        switch backendKind {
        case .cohereTranscribe:
            let modelsBase = MLModelConfigurationUtils.defaultModelsDirectory()
            try await ModelHub.download(.cohereTranscribeCoreml, to: modelsBase)

        case .parakeet:
            guard let version = Self.parakeetVersion(from: option) else {
                throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
            }
            _ = try await AsrModels.downloadAndLoad(version: version)

        case .streaming:
            guard let variant = Self.streamingVariant(from: option) else {
                throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
            }
            let manager = variant.createManager()
            try await manager.loadModels()
            await manager.cleanup()
        }
    }

    func beginPreviewSession(modelID: String) async throws {
        guard activePreviewSessionModelID == nil else { throw ASRServiceError.previewModelBusy }
        try await preparePreviewModelIfNeeded(modelID: modelID)
        guard let manager = loadedPreviewModel, loadedPreviewModelID == modelID else {
            throw ASRServiceError.finalManagerUnavailable(modelID: modelID)
        }
        try await manager.reset()
        activePreviewSessionModelID = modelID
    }

    func processPreviewChunk(_ chunk: PCMRecording) async throws -> String {
        guard activePreviewSessionModelID != nil, let manager = loadedPreviewModel else { return "" }
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0, !chunk.samples.isEmpty else { return "" }
        let samples = try AudioConverter().resample(chunk.samples, from: chunk.sampleRate)
        guard !samples.isEmpty else { return await manager.getPartialTranscript() }
        let buffer = try Self.makePCMBuffer(samples: samples)
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
        return await manager.getPartialTranscript()
    }

    func endPreviewSession() async {
        defer { activePreviewSessionModelID = nil }
        guard let manager = loadedPreviewModel else { return }
        try? await manager.reset()
    }

    private let coherePipeline = CoherePipeline()
    private var loadedPreviewModelID: String?
    private var loadedPreviewModel: (any StreamingAsrManager)?
    private var activePreviewSessionModelID: String?
    private var loadedFinalModelID: String?
    private var loadedFinalModel: LoadedFinalModel?
    private var lastFinalModelUse: ContinuousClock.Instant?
    private var activeFinalTranscriptions = 0
    private var queuedFinalTranscriptions = 0
    private var finalTranscriptionSlotIsOccupied = false
    private var finalTranscriptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var modelTransitionInProgress = false
    private var finalEvictionTask: Task<Void, Never>?

    /// A short silent input exercises both Cohere Core ML stages before the first user utterance.
    private static let finalModelWarmupAudio = [Float](
        repeating: 0,
        count: CohereAsrConfig.sampleRate
    )

    func preparePreviewModelIfNeeded(modelID: String) async throws {
        if let activePreviewSessionModelID, activePreviewSessionModelID != modelID {
            throw ASRServiceError.previewModelBusy
        }
        guard let option = modelCatalog.previewOption(id: modelID),
              let previewVariant = Self.streamingVariant(from: option)
        else {
            throw ASRServiceError.unsupportedPreviewModel(
                modelID: modelID,
                supportedModelIDs: modelCatalog.previewModels.map(\.id)
            )
        }
        guard loadedPreviewModelID != modelID || loadedPreviewModel == nil else { return }

        // Preview and final managers intentionally remain separate even when they use the same
        // checkpoint. A new recording may preview while the previous session finalizes; sharing a
        // stateful StreamingAsrManager would mix decoder state across those sessions.
        let manager = previewVariant.createManager()
        try await loadStreamingManagerLocally(
            manager,
            variant: previewVariant,
            modelID: modelID
        )

        let previousManager = loadedPreviewModel
        loadedPreviewModel = manager
        loadedPreviewModelID = modelID
        if let previousManager {
            await previousManager.cleanup()
        }
    }

    /// Cheap local-only validation used before the microphone starts. A missing final model is a
    /// recoverable Settings problem; discovering it after the user has already spoken would lose
    /// that utterance because Dicta deliberately never persists raw audio.
    func preflightFinalModel(modelID: String, language: InputLanguage) throws {
        guard let option = modelCatalog.finalOption(id: modelID) else {
            throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
        }
        try Self.validateLanguage(model: option, language: language)
        guard let backendKind = Self.supportedBackendKind(from: option) else {
            throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
        }

        switch backendKind {
        case .cohereTranscribe:
            let directory = MLModelConfigurationUtils.defaultModelsDirectory(
                for: .cohereTranscribeCoreml
            )
            try Self.requireInstalled(
                ModelNames.CohereTranscribe.requiredModels,
                in: directory,
                modelID: modelID
            )

        case .parakeet:
            guard let version = Self.parakeetVersion(from: option) else {
                throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
            }
            let directory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: directory, version: version) else {
                throw ASRServiceError.modelNotInstalled(modelID: modelID)
            }

        case .streaming:
            guard let variant = Self.streamingVariant(from: option) else {
                throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
            }
            let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: variant.repo)
            try Self.requireInstalled(
                ModelNames.ParakeetEOU.requiredModels,
                in: directory,
                modelID: modelID
            )
        }
    }

    /// Load a selected final model from FluidAudio's local cache. Model installation/download is a
    /// separate Settings concern; this method never turns a first dictation into a network fetch.
    func prepareFinalModelIfNeeded(modelID: String) async throws {
        if loadedFinalModelID == modelID, loadedFinalModel != nil {
            lastFinalModelUse = .now
            scheduleFinalEviction()
            return
        }
        guard !modelTransitionInProgress else { throw ASRServiceError.finalModelBusy }
        guard activeFinalTranscriptions == 0, queuedFinalTranscriptions == 0 else {
            throw ASRServiceError.finalModelBusy
        }
        modelTransitionInProgress = true
        defer { modelTransitionInProgress = false }

        let replacement = try await loadFinalModel(modelID: modelID)
        let previous = loadedFinalModel
        loadedFinalModel = replacement
        loadedFinalModelID = modelID
        lastFinalModelUse = .now
        scheduleFinalEviction()
        if let previous {
            await cleanup(previous)
        }
    }

    func transcribeFinal(session: DictationSession) async throws -> TranscriptResult {
        guard !modelTransitionInProgress else { throw ASRServiceError.finalModelBusy }
        queuedFinalTranscriptions += 1
        defer { queuedFinalTranscriptions -= 1 }

        await waitForFinalTranscriptionSlot()
        activeFinalTranscriptions += 1
        defer {
            activeFinalTranscriptions -= 1
            lastFinalModelUse = .now
            scheduleFinalEviction()
            releaseFinalTranscriptionSlot()
        }
        try Task.checkCancellation()

        guard let audio = session.audio else { throw ASRServiceError.missingAudio }
        guard !audio.samples.isEmpty else { throw ASRServiceError.emptyAudio }
        guard audio.sampleRate.isFinite, audio.sampleRate > 0,
              audio.samples.allSatisfy({ $0.isFinite })
        else { throw ASRServiceError.invalidAudio }
        guard loadedFinalModelID == session.finalModelID else {
            throw ASRServiceError.finalModelNotPrepared(modelID: session.finalModelID)
        }
        guard let finalModel = loadedFinalModel else {
            throw ASRServiceError.finalManagerUnavailable(modelID: session.finalModelID)
        }
        guard let modelOption = modelCatalog.finalOption(id: session.finalModelID) else {
            throw ASRServiceError.unsupportedFinalModel(modelID: session.finalModelID)
        }
        try Self.validateLanguage(model: modelOption, language: session.language)

        let samples: [Float]
        do {
            let converter = AudioConverter()
            samples = try converter.resample(audio.samples, from: audio.sampleRate)
        } catch {
            throw ASRServiceError.invalidAudio
        }
        guard !samples.isEmpty else { throw ASRServiceError.emptyAudio }

        let text: String
        switch finalModel {
        case .cohere(let pipeline, let models):
            guard let language = await session.language.cohereLanguage else {
                throw ASRServiceError.unsupportedLanguage(
                    modelID: session.finalModelID,
                    language: session.language
                )
            }
            let result = try await pipeline.transcribeLong(
                audio: samples,
                models: models,
                language: language
            )
            text = result.text

        case .parakeet(let manager):
            var decoderState = try TdtDecoderState(
                decoderLayers: await manager.decoderLayerCount
            )
            let result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: session.language.fluidAudioLanguage
            )
            text = result.text

        case .streaming(let manager):
            let buffer = try Self.makePCMBuffer(samples: samples)
            do {
                try await manager.appendAudio(buffer)
                try await manager.processBufferedAudio()
                text = try await manager.finish()
                try? await manager.reset()
            } catch {
                try? await manager.reset()
                throw error
            }
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ASRServiceError.emptyTranscript }
        return TranscriptResult(sessionID: session.id, text: normalized, completedAt: .now)
    }

    func evictFinalModelIfIdle() async {
        guard !modelTransitionInProgress,
              activeFinalTranscriptions == 0,
              queuedFinalTranscriptions == 0,
              let lastFinalModelUse,
              ContinuousClock().now - lastFinalModelUse >= Self.finalModelIdleLifetime,
              let finalModel = loadedFinalModel
        else { return }

        modelTransitionInProgress = true
        await cleanup(finalModel)

        loadedFinalModel = nil
        loadedFinalModelID = nil
        self.lastFinalModelUse = nil
        finalEvictionTask?.cancel()
        finalEvictionTask = nil
        modelTransitionInProgress = false
    }

    private func scheduleFinalEviction() {
        finalEvictionTask?.cancel()
        finalEvictionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: ASRService.finalModelIdleLifetime)
            } catch {
                return
            }
            await self?.evictFinalModelIfIdle()
        }
    }

    nonisolated static func isFinalModelIdle(
        lastUse: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) -> Bool {
        now - lastUse >= finalModelIdleLifetime
    }

    private func waitForFinalTranscriptionSlot() async {
        guard finalTranscriptionSlotIsOccupied else {
            finalTranscriptionSlotIsOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            finalTranscriptionWaiters.append(continuation)
        }
    }

    private func releaseFinalTranscriptionSlot() {
        if let waiter = finalTranscriptionWaiters.first {
            finalTranscriptionWaiters.removeFirst()
            waiter.resume()
        } else {
            finalTranscriptionSlotIsOccupied = false
        }
    }

    private func loadFinalModel(modelID: String) async throws -> LoadedFinalModel {
        guard let option = modelCatalog.finalOption(id: modelID) else {
            throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
        }
        guard let backendKind = Self.supportedBackendKind(from: option) else {
            throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
        }

        switch backendKind {
        case .cohereTranscribe:
            let directory = MLModelConfigurationUtils.defaultModelsDirectory(
                for: .cohereTranscribeCoreml
            )
            try Self.requireInstalled(
                ModelNames.CohereTranscribe.requiredModels,
                in: directory,
                modelID: modelID
            )
            let models = try await CoherePipeline.loadModels(
                encoderDir: directory,
                decoderDir: directory,
                vocabDir: directory
            )
            _ = try await coherePipeline.transcribe(
                audio: Self.finalModelWarmupAudio,
                models: models,
                language: .english,
                maxNewTokens: 1
            )
            return .cohere(coherePipeline, models)

        case .parakeet:
            guard let version = Self.parakeetVersion(from: option) else {
                throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
            }
            let directory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: directory, version: version) else {
                throw ASRServiceError.modelNotInstalled(modelID: modelID)
            }
            do {
                let models = try await AsrModels.load(from: directory, version: version)
                return .parakeet(AsrManager(models: models))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ASRServiceError.modelNotInstalled(modelID: modelID)
            }

        case .streaming:
            guard let variant = Self.streamingVariant(from: option) else {
                throw ASRServiceError.unsupportedFinalModel(modelID: modelID)
            }
            let manager = variant.createManager()
            try await loadStreamingManagerLocally(
                manager,
                variant: variant,
                modelID: modelID
            )
            return .streaming(manager)
        }
    }

    /// Verify all required files before invoking FluidAudio's convenience loader so runtime
    /// preparation cannot turn into a network fetch. Avoid mutating ModelHub.offlineMode: it is
    /// process-global and would create a race with a Settings download while this actor is
    /// suspended.
    private func loadStreamingManagerLocally(
        _ manager: any StreamingAsrManager,
        variant: StreamingModelVariant,
        modelID: String
    ) async throws {
        let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: variant.repo)
        try Self.requireInstalled(
            ModelNames.ParakeetEOU.requiredModels,
            in: directory,
            modelID: modelID
        )

        do {
            try await manager.loadModels()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ASRServiceError.modelNotInstalled(modelID: modelID)
        }
    }

    private func cleanup(_ model: LoadedFinalModel) async {
        switch model {
        case .cohere:
            // CoherePipeline.LoadedModels is a value containing Core ML references; releasing the
            // enum case is its cleanup operation because FluidAudio exposes no cleanup method.
            break
        case .parakeet(let manager):
            await manager.cleanup()
        case .streaming(let manager):
            await manager.cleanup()
        }
    }

    private nonisolated static func requireInstalled(
        _ files: Set<String>,
        in directory: URL,
        modelID: String
    ) throws {
        let missing = files.filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            throw ASRServiceError.modelNotInstalled(modelID: modelID)
        }
    }

    private nonisolated static func supportedBackendKind(
        from option: ASRModelOption
    ) -> SupportedBackendKind? {
        SupportedBackendKind(rawValue: option.backend.kind.rawValue)
    }

    private nonisolated static func streamingVariant(
        from option: ASRModelOption
    ) -> StreamingModelVariant? {
        guard option.backend.kind == .streaming else { return nil }
        guard let variantID = option.backend.variantID,
              let variant = StreamingModelVariant(rawValue: variantID),
              variant.engineFamily == .parakeetEou
        else { return nil }
        return variant
    }

    private nonisolated static func parakeetVersion(
        from option: ASRModelOption
    ) -> AsrModelVersion? {
        guard option.backend.kind == .parakeet,
              let versionID = option.backend.variantID
        else { return nil }

        switch versionID {
        case "v2": return .v2
        case "v3": return .v3
        case "tdt-ja": return .tdtJa
        default: return nil
        }
    }

    private nonisolated static func validateLanguage(
        model: ASRModelOption,
        language: InputLanguage
    ) throws {
        guard language != .automatic, model.supports(language) else {
            throw ASRServiceError.unsupportedLanguage(modelID: model.id, language: language)
        }
    }

    private nonisolated static func makePCMBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let channelData = buffer.floatChannelData
        else { throw ASRServiceError.audioBufferCreationFailed }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }
        return buffer
    }
}
