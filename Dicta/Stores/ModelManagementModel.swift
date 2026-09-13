import Foundation
import Observation

@MainActor
@Observable
final class ModelManagementModel {
    private enum Request: Equatable {
        case preview(String)
        case final(String)
        case remove(String)
        case vad

        var operationID: String {
            switch self {
            case .preview(let id), .final(let id), .remove(let id): id
            case .vad: "silero-vad"
            }
        }

        var role: Role {
            switch self {
            case .preview: .preview
            case .final: .final
            case .remove: .storage
            case .vad: .vad
            }
        }

        enum Role {
            case preview
            case final
            case storage
            case vad
        }
    }

    private let asrService: ASRService
    private let vadService: VADService
    private let storageService: ModelStorageService
    private let appModel: AppModel

    private var pending: [Request] = []
    private var workerTask: Task<Void, Never>?

    private(set) var activeOperationID: String?
    private(set) var queuedOperationCount = 0
    private(set) var statusMessage: String?
    private(set) var installedModelIDs: Set<String> = []

    init(
        asrService: ASRService,
        vadService: VADService,
        storageService: ModelStorageService,
        appModel: AppModel
    ) {
        self.asrService = asrService
        self.vadService = vadService
        self.storageService = storageService
        self.appModel = appModel

        Task { [weak self] in
            await self?.refreshInstalledModels()
        }
    }

    func isInstalled(modelID: String) -> Bool {
        installedModelIDs.contains(modelID)
    }

    func installPreview(modelID: String) {
        guard !modelID.isEmpty else { return }
        enqueue(.preview(modelID))
    }

    func installFinal(modelID: String) {
        guard !modelID.isEmpty else { return }
        enqueue(.final(modelID))
    }

    func removeModel(modelID: String) {
        guard !modelID.isEmpty else { return }
        enqueue(.remove(modelID))
    }

    func installVAD() {
        enqueue(.vad)
    }

    func refreshInstalledModels() async {
        installedModelIDs = await storageService.installedModelIDs()
    }

    private func enqueue(_ request: Request) {
        guard activeOperationID != request.operationID || pending.contains(request) else { return }

        pending.removeAll { $0.role == request.role && $0.operationID == request.operationID }
        guard !pending.contains(request) else { return }
        pending.append(request)
        queuedOperationCount = pending.count
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { @MainActor [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        defer {
            activeOperationID = nil
            queuedOperationCount = 0
            workerTask = nil
        }

        while !pending.isEmpty {
            let request = pending.removeFirst()
            queuedOperationCount = pending.count
            activeOperationID = request.operationID

            do {
                switch request {
                case .preview(let modelID):
                    statusMessage = "Downloading model…"
                    try await asrService.installPreviewModel(modelID: modelID)
                    statusMessage = "Model downloaded."

                case .final(let modelID):
                    statusMessage = "Downloading model…"
                    try await asrService.installFinalModel(modelID: modelID)
                    statusMessage = "Model downloaded."

                case .remove(let modelID):
                    statusMessage = "Removing model…"
                    try await storageService.removeModel(modelID: modelID)
                    statusMessage = "Model removed."

                case .vad:
                    statusMessage = "Downloading speech detector…"
                    try await vadService.install()
                    statusMessage = "Speech detector is ready."
                }

                await refreshInstalledModels()
            } catch {
                statusMessage = nil
                appModel.report(error)
                await refreshInstalledModels()
            }
        }
    }
}
