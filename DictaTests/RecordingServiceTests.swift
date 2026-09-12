import AVFoundation
import Foundation
import Testing
@testable import Dicta

@Test
func recordingServiceDownmixesFloat32InputToMono() {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
    buffer.frameLength = 3

    let channels = buffer.floatChannelData!
    channels[0][0] = 0
    channels[0][1] = 1
    channels[0][2] = -0.5
    channels[1][0] = 0.5
    channels[1][1] = -1
    channels[1][2] = 0.5

    #expect(RecordingService.monoSamples(from: buffer) == [0.25, 0, 0])
}

@Test
func stoppingIdleRecordingServiceIsSafe() async throws {
    let service = RecordingService()
    let captured = try await service.stop()
    #expect(captured == nil)

    let state = await service.state
    if case .idle = state {
        // Expected.
    } else {
        Issue.record("Stopping while idle must leave the service idle")
    }
}

@Test
func cancellingIdleRecordingServiceIsSafe() async {
    let service = RecordingService()
    await service.cancel()

    let state = await service.state
    if case .idle = state {
        // Expected.
    } else {
        Issue.record("Cancelling while idle must leave the service idle")
    }
}
