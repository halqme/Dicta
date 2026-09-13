import Foundation

@MainActor
final class AppEnvironment {
    let appModel: AppModel
    let settings: SettingsStore
    let modelManagement: ModelManagementModel
    let controller: DictationController
    let hotKeyService: GlobalHotKeyService?
    let windowPresenter: WindowPresentationService

    /// A caller may inject a catalog for tests. Normal startup prefers the last-known-good cached
    /// remote manifest and falls back to the bundled catalog.
    init(modelCatalog injectedCatalog: ModelCatalog? = nil) {
        let shouldRefreshCatalog = injectedCatalog == nil
        let modelCatalog = injectedCatalog ?? ModelCatalogLoader.loadStartupCatalog()

        let appModel = AppModel()
        let settings = SettingsStore(modelCatalog: modelCatalog)
        let recordingService = RecordingService()
        let asrService = ASRService(modelCatalog: modelCatalog)
        let vadService = VADService()
        let inputDeliveryService = InputDeliveryService()
        let targetResolver = TargetResolver(inputDeliveryService: inputDeliveryService)
        let finalizationQueue = FinalizationQueue()
        let historyStore = HistoryStore()
        let windowPresenter = WindowPresentationService()

        let hotKeyService: GlobalHotKeyService?
        do {
            hotKeyService = try GlobalHotKeyService()
        } catch {
            hotKeyService = nil
            appModel.report(error)
        }

        let controller = DictationController(
            appModel: appModel,
            settings: settings,
            recordingService: recordingService,
            asrService: asrService,
            vadService: vadService,
            targetResolver: targetResolver,
            inputDeliveryService: inputDeliveryService,
            finalizationQueue: finalizationQueue,
            historyStore: historyStore,
            windowPresenter: windowPresenter,
            hotKeyService: hotKeyService
        )
        let modelManagement = ModelManagementModel(
            asrService: asrService,
            vadService: vadService,
            appModel: appModel
        )

        self.appModel = appModel
        self.settings = settings
        self.modelManagement = modelManagement
        self.controller = controller
        self.hotKeyService = hotKeyService
        self.windowPresenter = windowPresenter

        hotKeyService?.onPressed = { [weak controller] in
            controller?.handleHotKeyPressed()
        }
        hotKeyService?.onReleased = { [weak controller] in
            controller?.handleHotKeyReleased()
        }
        hotKeyService?.onCancel = { [weak controller] in
            controller?.cancelCurrent()
        }

        registerCurrentHotKey()
        controller.bootstrap()

        if shouldRefreshCatalog {
            Task.detached(priority: .utility) {
                await ModelCatalogLoader.refreshCache()
            }
        }
    }

    func registerCurrentHotKey() {
        guard let hotKeyService else { return }
        let previous = hotKeyService.registeredConfiguration
        do {
            try hotKeyService.register(settings.hotKey)
        } catch {
            // Registration is transactional inside GlobalHotKeyService. Keep Settings in sync
            // with the shortcut that is still actually registered after a conflict.
            if let previous, settings.hotKey != previous {
                settings.hotKey = previous
            }
            appModel.report(error)
        }
    }
}
