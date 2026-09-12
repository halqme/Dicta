import CoreML
import Foundation
import FluidAudio

actor VADService {
    enum VADError: LocalizedError, Sendable {
        case modelNotInstalled

        var errorDescription: String? {
            switch self {
            case .modelNotInstalled:
                "Silero VAD is not installed. Install the speech detector from Dicta Settings before enabling silence auto-finish."
            }
        }
    }

    private static let compiledModelName = "silero-vad-unified-256ms-v6.2.1.mlmodelc"

    private var manager: VadManager?
    private var streamState: VadStreamState?
    private var segmentationConfig = VadSegmentationConfig.default
    private var initialSilenceLimitSamples = 0
    private var processedSamples = 0
    private var hasDetectedSpeech = false

    /// Explicit network-enabled installation path used only from Settings.
    func install() async throws {
        manager = try await VadManager()
    }

    /// Runtime loading never downloads. This preserves the rule that starting a dictation cannot
    /// unexpectedly fetch models from the network.
    func prepareIfInstalled() async throws {
        if manager != nil { return }

        let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)
        let modelURL = directory.appendingPathComponent(Self.compiledModelName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VADError.modelNotInstalled
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        manager = VadManager(config: .default, vadModel: model)
    }

    func beginSession(silenceDuration: Double) async throws {
        try await prepareIfInstalled()
        guard let manager else { return }

        var config = VadSegmentationConfig.default
        config.minSilenceDuration = max(0.5, min(5, silenceDuration))
        segmentationConfig = config
        initialSilenceLimitSamples = Int(config.minSilenceDuration * Double(VadManager.sampleRate))
        processedSamples = 0
        hasDetectedSpeech = false
        streamState = await manager.makeStreamState()
    }

    /// Returns true exactly when Silero emits a speech-end boundary after the configured silence.
    func process(_ chunk: PCMRecording) async throws -> Bool {
        guard let manager, let state = streamState else { return false }
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0, !chunk.samples.isEmpty else {
            return false
        }

        let samples = try AudioConverter().resample(chunk.samples, from: chunk.sampleRate)
        guard !samples.isEmpty else { return false }
        processedSamples += samples.count
        let result = try await manager.processStreamingChunk(
            samples,
            state: state,
            config: segmentationConfig,
            returnSeconds: false
        )
        streamState = result.state

        if let event = result.event {
            switch event.kind {
            case .speechEnd:
                return true
            case .speechStart:
                hasDetectedSpeech = true
                return false
            }
        }

        // Silero emits speechEnd only after speechStart. Treat "the user never began speaking" as
        // silence too, otherwise a Toggle session started by accident would stay open forever.
        return !hasDetectedSpeech
            && initialSilenceLimitSamples > 0
            && processedSamples >= initialSilenceLimitSamples
    }

    func endSession() {
        streamState = nil
        processedSamples = 0
        hasDetectedSpeech = false
    }
}
