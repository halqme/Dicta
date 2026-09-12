@preconcurrency import AVFoundation
import Foundation
import os

/// Owns microphone capture and in-memory PCM for exactly one active recording session.
/// Finalization is intentionally handed off so the microphone can immediately serve the next session.
actor RecordingService {
    enum State: Sendable {
        case idle
        case recording(sessionID: UUID)
    }

    enum RecordingError: LocalizedError, Sendable, Equatable {
        case microphonePermissionDenied
        case inputUnavailable
        case unsupportedInputFormat
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                "Microphone access was denied. Enable microphone access for Dicta in System Settings > Privacy & Security > Microphone."
            case .inputUnavailable:
                "The system-default microphone is unavailable or has no audio input format."
            case .unsupportedInputFormat:
                "The system-default microphone returned an unsupported PCM format."
            case let .engineStartFailed(details):
                "The microphone could not start recording: \(details)"
            }
        }
    }

    private struct AccumulatorState: Sendable {
        var samples: [Float] = []
        var sampleRate: Double = 0
        var acceptingSamples = false
        var streamContinuation: AsyncStream<PCMRecording>.Continuation?
    }

    private(set) var state: State = .idle
    private let accumulator = OSAllocatedUnfairLock(initialState: AccumulatorState())
    private var audioEngine: AVAudioEngine?
    private var tapInstalled = false
    private var startRequestID: UUID?

    func start(sessionID: UUID) async throws -> AsyncStream<PCMRecording> {
        guard case .idle = state, startRequestID == nil else {
            return AsyncStream { $0.finish() }
        }
        let requestID = UUID()
        startRequestID = requestID
        defer {
            if startRequestID == requestID {
                startRequestID = nil
            }
        }

        let permissionGranted = await Self.microphonePermissionGranted()
        try Task.checkCancellation()

        // Cancellation can arrive while the permission prompt is suspended.
        guard startRequestID == requestID, case .idle = state else {
            return AsyncStream { $0.finish() }
        }
        guard permissionGranted else {
            throw RecordingError.microphonePermissionDenied
        }

        // AVAudioEngine's input node follows the current macOS system-default input device.
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecordingError.inputUnavailable
        }
        guard Self.isSupportedPCMFormat(inputFormat.commonFormat) else {
            throw RecordingError.unsupportedInputFormat
        }

        let (stream, continuation) = AsyncStream<PCMRecording>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )

        accumulator.withLock { buffer in
            buffer.samples.removeAll(keepingCapacity: false)
            buffer.sampleRate = inputFormat.sampleRate
            buffer.acceptingSamples = true
            buffer.streamContinuation = continuation
        }

        inputNode.installTap(onBus: 0, bufferSize: 8_192, format: inputFormat) { [accumulator] buffer, _ in
            let samples = RecordingService.monoSamples(from: buffer)
            guard !samples.isEmpty else { return }
            let chunk = PCMRecording(samples: samples, sampleRate: buffer.format.sampleRate)
            accumulator.withLock { captured in
                guard captured.acceptingSamples else { return }
                captured.samples.append(contentsOf: samples)
                captured.streamContinuation?.yield(chunk)
            }
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            accumulator.withLock { buffer in
                buffer.acceptingSamples = false
                buffer.streamContinuation?.finish()
                buffer.streamContinuation = nil
                buffer.samples.removeAll(keepingCapacity: false)
                buffer.sampleRate = 0
            }
            throw RecordingError.engineStartFailed(error.localizedDescription)
        }

        audioEngine = engine
        state = .recording(sessionID: sessionID)
        return stream
    }

    /// Stop the active capture and transfer ownership of the copied PCM to finalization.
    /// Stopping while idle is a safe no-op.
    func stop() async throws -> CapturedAudio? {
        guard case .recording = state else {
            startRequestID = nil
            return nil
        }

        stopEngineAndTap()
        let captured = accumulator.withLock { buffer -> CapturedAudio? in
            defer {
                buffer.acceptingSamples = false
                buffer.streamContinuation?.finish()
                buffer.streamContinuation = nil
                buffer.samples.removeAll(keepingCapacity: false)
                buffer.sampleRate = 0
            }
            guard !buffer.samples.isEmpty, buffer.sampleRate > 0 else { return nil }
            return CapturedAudio(samples: buffer.samples, sampleRate: buffer.sampleRate)
        }
        state = .idle
        return captured
    }

    /// Cancel the active capture and discard all audio without producing a transcript.
    func cancel() async {
        startRequestID = nil
        stopEngineAndTap()
        accumulator.withLock { buffer in
            buffer.acceptingSamples = false
            buffer.streamContinuation?.finish()
            buffer.streamContinuation = nil
            buffer.samples.removeAll(keepingCapacity: false)
            buffer.sampleRate = 0
        }
        state = .idle
    }

    private func stopEngineAndTap() {
        if tapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine?.stop()
        audioEngine = nil
    }

    private nonisolated static func microphonePermissionGranted() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private nonisolated static func isSupportedPCMFormat(_ format: AVAudioCommonFormat) -> Bool {
        switch format {
        case .pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32:
            return true
        default:
            return false
        }
    }

    /// Copy a PCM buffer immediately on the audio callback thread and downmix it to mono.
    nonisolated static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let interleaved = buffer.format.isInterleaved

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            if interleaved {
                guard let data = buffers.first?.mData else { return [] }
                let samples = data.assumingMemoryBound(to: Float.self)
                return downmix(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                    samples[frame * channelCount + channel]
                }
            }
            guard let channelData = buffer.floatChannelData else { return [] }
            return downmix(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                channelData[channel][frame]
            }

        case .pcmFormatFloat64:
            if interleaved {
                guard let data = buffers.first?.mData else { return [] }
                let samples = data.assumingMemoryBound(to: Double.self)
                return downmix(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                    Float(samples[frame * channelCount + channel])
                }
            }
            return downmix(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                guard channel < buffers.count, let data = buffers[channel].mData else { return 0 }
                let samples = data.assumingMemoryBound(to: Double.self)
                return Float(samples[frame])
            }

        case .pcmFormatInt16:
            if interleaved {
                guard let data = buffers.first?.mData else { return [] }
                let samples = data.assumingMemoryBound(to: Int16.self)
                return downmix(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                    Float(samples[frame * channelCount + channel]) / 32_768
                }
            }
            guard let channelData = buffer.int16ChannelData else { return [] }
            return downmix(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                Float(channelData[channel][frame]) / 32_768
            }

        case .pcmFormatInt32:
            if interleaved {
                guard let data = buffers.first?.mData else { return [] }
                let samples = data.assumingMemoryBound(to: Int32.self)
                return downmix(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                    Float(samples[frame * channelCount + channel]) / 2_147_483_648
                }
            }
            guard let channelData = buffer.int32ChannelData else { return [] }
            return downmix(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                Float(channelData[channel][frame]) / 2_147_483_648
            }

        default:
            return []
        }
    }

    private nonisolated static func downmix(
        frameCount: Int,
        channelCount: Int,
        sample: (Int, Int) -> Float
    ) -> [Float] {
        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(frameCount)
        let divisor = Float(channelCount)

        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += sample(channel, frame)
            }
            monoSamples.append(sum / divisor)
        }
        return monoSamples
    }
}
