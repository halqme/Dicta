import Foundation

@MainActor
final class DictationController {
    private static let maximumOutstandingFinalizations = 10

    private struct ActiveCapture {
        let id: UUID
        let startedAt: Date
        let language: InputLanguage
        let finalModelID: String
        let target: DictationTarget
        let warmupTask: Task<Void, Error>
        var streamTask: Task<Void, Never>?
    }

    private let appModel: AppModel
    private let settings: SettingsStore
    private let recordingService: RecordingService
    private let asrService: ASRService
    private let vadService: VADService
    private let targetResolver: TargetResolver
    private let inputDeliveryService: InputDeliveryService
    private let finalizationQueue: FinalizationQueue
    private let historyStore: HistoryStore
    private let windowPresenter: WindowPresentationService
    private let hotKeyService: GlobalHotKeyService?

    private var activeCapture: ActiveCapture?
    private var pendingStartTask: Task<Void, Never>?
    private var isFinishingCapture = false
    private var outstandingFinalizations = 0

    init(
        appModel: AppModel,
        settings: SettingsStore,
        recordingService: RecordingService,
        asrService: ASRService,
        vadService: VADService,
        targetResolver: TargetResolver,
        inputDeliveryService: InputDeliveryService,
        finalizationQueue: FinalizationQueue,
        historyStore: HistoryStore,
        windowPresenter: WindowPresentationService,
        hotKeyService: GlobalHotKeyService?
    ) {
        self.appModel = appModel
        self.settings = settings
        self.recordingService = recordingService
        self.asrService = asrService
        self.vadService = vadService
        self.targetResolver = targetResolver
        self.inputDeliveryService = inputDeliveryService
        self.finalizationQueue = finalizationQueue
        self.historyStore = historyStore
        self.windowPresenter = windowPresenter
        self.hotKeyService = hotKeyService
    }

    func bootstrap() {
        Task { @concurrent [historyStore, appModel] in
            do {
                let items = try await historyStore.load()
                await MainActor.run { appModel.setHistory(items) }
            } catch {
                await MainActor.run { appModel.report(error) }
            }
        }

        let previewModelID = settings.previewModelID
        if !previewModelID.isEmpty {
            Task { @concurrent [asrService] in
                // Missing models are intentionally silent at launch; Settings owns downloading.
                try? await asrService.preparePreviewModelIfNeeded(modelID: previewModelID)
            }
        }
    }

    func handleHotKeyPressed() {
        switch settings.captureMode {
        case .pushToTalk:
            requestStart()
        case .toggle:
            if activeCapture != nil || pendingStartTask != nil {
                requestFinish()
            } else {
                requestStart()
            }
        }
    }

    func handleHotKeyReleased() {
        guard settings.captureMode == .pushToTalk else { return }
        if pendingStartTask != nil, activeCapture == nil {
            pendingStartTask?.cancel()
        } else {
            requestFinish()
        }
    }

    func toggleFromMenu() {
        if activeCapture != nil || pendingStartTask != nil {
            requestFinish()
        } else {
            requestStart()
        }
    }

    func cancelCurrent() {
        if let pendingStartTask, activeCapture == nil {
            pendingStartTask.cancel()
            self.pendingStartTask = nil
        }
        guard activeCapture != nil else { return }
        Task { @MainActor [weak self] in
            await self?.performCancel()
        }
    }

    func showFallbackEditor() {
        windowPresenter.showFallbackEditor(appModel: appModel)
    }

    func clearHistory() {
        Task { @concurrent [historyStore, appModel] in
            do {
                try await historyStore.clear()
                await MainActor.run { appModel.setHistory([]) }
            } catch {
                await MainActor.run { appModel.report(error) }
            }
        }
    }

    private func requestStart() {
        guard outstandingFinalizations < Self.maximumOutstandingFinalizations else {
            appModel.report(message: "Dicta is still finalizing 10 recordings. Let the queue drain before recording another one.")
            return
        }
        guard activeCapture == nil,
              pendingStartTask == nil,
              !isFinishingCapture
        else { return }

        pendingStartTask = Task { @MainActor [weak self] in
            await self?.performStart()
        }
    }

    private func requestFinish() {
        if activeCapture == nil {
            pendingStartTask?.cancel()
            pendingStartTask = nil
            return
        }
        guard !isFinishingCapture else { return }
        Task { @MainActor [weak self] in
            await self?.performFinish()
        }
    }

    private func performStart() async {
        defer { pendingStartTask = nil }
        let sessionID = UUID()
        let language = settings.language
        let finalModelID = settings.finalModelID
        let previewModelID = settings.previewModelID
        let shouldUsePreview = !previewModelID.isEmpty
        let shouldUseVAD = settings.captureMode == .toggle && settings.silenceAutoFinish
        let silenceDuration = settings.silenceDuration

        var resolvedTarget: DictationTarget?
        do {
            // Do not accept speech that cannot possibly be finalized. This checks only local files;
            // downloading still belongs exclusively to Settings.
            try await asrService.preflightFinalModel(modelID: finalModelID, language: language)
            try Task.checkCancellation()
            let target = await targetResolver.resolveCurrentTarget()
            resolvedTarget = target
            try Task.checkCancellation()
            let stream = try await recordingService.start(sessionID: sessionID)
            try Task.checkCancellation()

            let warmupTask = Task { @concurrent [asrService, finalModelID] in
                try await asrService.prepareFinalModelIfNeeded(modelID: finalModelID)
            }

            activeCapture = ActiveCapture(
                id: sessionID,
                startedAt: .now,
                language: language,
                finalModelID: finalModelID,
                target: target,
                warmupTask: warmupTask,
                streamTask: nil
            )
            appModel.beginRecording()
            windowPresenter.showLiveHUD(appModel: appModel)
            hotKeyService?.setCancelShortcutEnabled(true)

            let streamTask = Task { @concurrent [
                asrService,
                vadService,
                weak self
            ] in
                var previewReady = false
                var vadReady = false

                if shouldUsePreview {
                    do {
                        try await asrService.beginPreviewSession(modelID: previewModelID)
                        previewReady = true
                    } catch {
                        // Preview is non-authoritative. Final transcription must remain usable when
                        // a preview model is missing or fails to initialize.
                    }
                }

                if shouldUseVAD {
                    do {
                        try await vadService.beginSession(silenceDuration: silenceDuration)
                        vadReady = true
                    } catch {
                        await MainActor.run { self?.appModel.report(error) }
                    }
                }

                for await chunk in stream {
                    if Task.isCancelled { break }
                    do {
                        var previewText: String?
                        var shouldAutoFinish = false

                        if vadReady {
                            shouldAutoFinish = try await vadService.process(chunk)
                        }
                        if shouldAutoFinish {
                            await MainActor.run {
                                guard self?.activeCapture?.id == sessionID else { return }
                                self?.requestFinish()
                            }
                            break
                        }
                        if previewReady {
                            previewText = try await asrService.processPreviewChunk(chunk)
                        }

                        if let previewText, !previewText.isEmpty {
                            await MainActor.run {
                                guard self?.activeCapture?.id == sessionID else { return }
                                self?.appModel.previewText = previewText
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        // Preview/VAD failure does not destroy the captured final audio.
                        await MainActor.run { self?.appModel.report(error) }
                    }
                }

                if previewReady { await asrService.endPreviewSession() }
                if vadReady { await vadService.endSession() }
            }
            activeCapture?.streamTask = streamTask
        } catch is CancellationError {
            await recordingService.cancel()
            if let resolvedTarget { await inputDeliveryService.discard(resolvedTarget) }
        } catch {
            await recordingService.cancel()
            if let resolvedTarget { await inputDeliveryService.discard(resolvedTarget) }
            appModel.report(error)
        }
    }

    private func performFinish() async {
        guard let capture = activeCapture else { return }
        isFinishingCapture = true
        capture.streamTask?.cancel()

        do {
            let audio = try await recordingService.stop()
            await asrService.endPreviewSession()
            await vadService.endSession()

            activeCapture = nil
            isFinishingCapture = false
            appModel.finishRecording()
            windowPresenter.hideLiveHUD()
            hotKeyService?.setCancelShortcutEnabled(false)

            guard let audio, !audio.samples.isEmpty else {
                capture.warmupTask.cancel()
                await inputDeliveryService.discard(capture.target)
                appModel.report(message: "No microphone audio was captured.")
                return
            }

            let session = DictationSession(
                id: capture.id,
                startedAt: capture.startedAt,
                language: capture.language,
                finalModelID: capture.finalModelID,
                target: capture.target,
                audio: audio
            )
            let keepHistory = settings.keepHistory
            await enqueueFinalization(
                session: session,
                warmupTask: capture.warmupTask,
                keepHistory: keepHistory
            )
        } catch {
            capture.warmupTask.cancel()
            await recordingService.cancel()
            await inputDeliveryService.discard(capture.target)
            activeCapture = nil
            isFinishingCapture = false
            appModel.cancelRecording()
            windowPresenter.hideLiveHUD()
            hotKeyService?.setCancelShortcutEnabled(false)
            appModel.report(error)
        }
    }

    private func performCancel() async {
        guard let capture = activeCapture else { return }
        capture.streamTask?.cancel()
        capture.warmupTask.cancel()
        await recordingService.cancel()
        await asrService.endPreviewSession()
        await vadService.endSession()
        await inputDeliveryService.discard(capture.target)

        activeCapture = nil
        isFinishingCapture = false
        appModel.cancelRecording()
        windowPresenter.hideLiveHUD()
        hotKeyService?.setCancelShortcutEnabled(false)
    }

    private func enqueueFinalization(
        session: DictationSession,
        warmupTask: Task<Void, Error>,
        keepHistory: Bool
    ) async {
        outstandingFinalizations += 1
        appModel.setQueuedFinalizations(outstandingFinalizations)

        let asrService = self.asrService
        let inputDeliveryService = self.inputDeliveryService
        let historyStore = self.historyStore
        let appModel = self.appModel
        let windowPresenter = self.windowPresenter

        await finalizationQueue.enqueue { [weak self] in
                do {
                    do {
                        try await warmupTask.value
                    } catch {
                        // Warm-up may have collided with another model currently finalizing.
                        // At FIFO execution time the heavy lane is available, so retry here.
                        try await asrService.prepareFinalModelIfNeeded(modelID: session.finalModelID)
                    }

                    let result = try await asrService.transcribeFinal(session: session)
                    let destination: TranscriptHistoryItem.Destination
                    do {
                        destination = try await inputDeliveryService.deliver(result, to: session.target)
                    } catch {
                        await inputDeliveryService.discard(session.target)
                        destination = .fallbackEditor
                    }

                    if destination == .fallbackEditor {
                        await MainActor.run {
                            appModel.appendFallback(result.text)
                            windowPresenter.showFallbackEditor(appModel: appModel)
                        }
                    }

                    if keepHistory {
                        let item = TranscriptHistoryItem(
                            id: UUID(),
                            createdAt: result.completedAt,
                            text: result.text,
                            destination: destination
                        )
                        do {
                            let items = try await historyStore.append(item)
                            await MainActor.run { appModel.setHistory(items) }
                        } catch {
                            await MainActor.run { appModel.report(error) }
                        }
                    }
                } catch {
                    await inputDeliveryService.discard(session.target)
                    await MainActor.run { appModel.report(error) }
                }

                await MainActor.run {
                    self?.finalizationDidComplete()
                }
            }
    }

    private func finalizationDidComplete() {
        outstandingFinalizations = max(0, outstandingFinalizations - 1)
        appModel.setQueuedFinalizations(outstandingFinalizations)
    }
}
