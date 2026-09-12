import Foundation
import Testing
@testable import Dicta

@Test
func previewCatalogContainsOnlySmallStreamingModels() {
    #expect(
        ModelCatalog.builtIn.previewModels.map(\.id) == [
            "parakeet-eou-160ms",
            "parakeet-eou-320ms",
            "parakeet-eou-1280ms",
        ])
}

@Test
func unsupportedPreviewModelFailsBeforeLoading() async {
    let modelID = "unsupported-preview"
    let expected = ASRServiceError.unsupportedPreviewModel(
        modelID: modelID,
        supportedModelIDs: ModelCatalog.builtIn.previewModels.map(\.id)
    )
    var error: ASRServiceError?

    do {
        try await ASRService().preparePreviewModelIfNeeded(modelID: modelID)
    } catch let serviceError as ASRServiceError {
        error = serviceError
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(error == expected)
    #expect(error?.errorDescription?.contains(modelID) == true)
}

private func makeSession(audio: PCMRecording? = nil) -> DictationSession {
    DictationSession(
        language: .english,
        finalModelID: "test-model",
        target: .fallbackEditor,
        audio: audio
    )
}

@Test
func finalTranscriptionRejectsMissingAudio() async {
    let service = ASRService()
    var error: ASRServiceError?

    do {
        _ = try await service.transcribeFinal(session: makeSession())
    } catch let thrownError as ASRServiceError {
        error = thrownError
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(error == .missingAudio)
}

@Test
func finalTranscriptionRejectsEmptyAudio() async {
    let service = ASRService()
    var error: ASRServiceError?

    do {
        _ = try await service.transcribeFinal(session: makeSession(audio: PCMRecording(samples: [])))
    } catch let thrownError as ASRServiceError {
        error = thrownError
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(error == .emptyAudio)
}

@Test
func finalTranscriptionRejectsAnUnpreparedModel() async {
    let service = ASRService()
    var error: ASRServiceError?

    do {
        _ = try await service.transcribeFinal(
            session: makeSession(audio: PCMRecording(samples: [0.1]))
        )
    } catch let thrownError as ASRServiceError {
        error = thrownError
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(error == .finalModelNotPrepared(modelID: "test-model"))
}

@Test
func finalModelIdleDecisionUsesTheTenMinuteBoundary() {
    let now = ContinuousClock().now
    let exactlyIdle = now.advanced(by: .seconds(-10 * 60))
    let stillActive = now.advanced(by: .seconds(-(10 * 60) + 1))

    #expect(ASRService.finalModelIdleLifetime == .seconds(10 * 60))
    #expect(ASRService.isFinalModelIdle(lastUse: exactlyIdle, now: now))
    #expect(!ASRService.isFinalModelIdle(lastUse: stillActive, now: now))
}
