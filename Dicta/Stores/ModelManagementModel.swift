import Foundation
import Observation

@MainActor
@Observable
final class ModelManagementModel {
    private enum InstallRequest: Equatable {
        case preview(String)
        case final(String)
        case vad

        var operationID: String {
            switch self {
            case .preview(let id), .final(let id): id
            case .vad: "silero-vad"
            }
        }

        var role: Role {
            switch self {
            case .preview: .preview
            case .final: .final
            case .vad: .vad
            }
        }

        enum Role {
            case preview
            case final
            case vad
        }
    }

    private let asrService: ASRService
    private let vadService: VADService
    private let appModel: AppModel

    private var pending: [InstallRequest] = []
    private var workerTask: Task<Void, Never>?

    private(set) var activeOperationID: String?
    private(set) var queuedOperationCount = 0
    private(set) var statusMessage: String?

    init(asrService: ASRService, vadService: VADService, appModel: AppModel) {
        self.asrService = asrService
        self.vadService = vadService
        self.appModel = appModel
    }

    func installPreview(modelID: String) {
        guard !modelID.isEmpty else { return }
        enqueue(.preview(modelID))
    }

    func installFinal(modelID: String) {
        guard !modelID.isEmpty else { return }
        enqueue(.final(modelID))
    }

    func installVAD() {
        enqueue(.vad)
    }

    private func enqueue(_ request: InstallRequest) {
        if activeOperationID == request.operationID,
           pending.contains(where: { $0 == request }) == false {
            return
        }

        // Settings changes can normalize both preview and final selections at once. Serialize
        // downloads instead of silently dropping the second request. For repeated changes in the
        // same role, only the latest pending selection is useful.
        pending.removeAll { $0.role == request.role }
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
                    statusMessage = "Downloading preview model…"
                    try await asrService.installPreviewModel(modelID: modelID)
                    statusMessage = "Preview model is ready."

                case .final(let modelID):
                    statusMessage = "Downloading final model…"
                    try await asrService.installFinalModel(modelID: modelID)
                    statusMessage = "Final model is installed."

                case .vad:
                    statusMessage = "Downloading speech detector…"
                    try await vadService.install()
                    statusMessage = "Speech detector is ready."
                }
            } catch {
                statusMessage = nil
                appModel.report(error)
            }
        }
    }
}
