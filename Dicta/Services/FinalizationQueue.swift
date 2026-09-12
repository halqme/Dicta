import Foundation

/// Serializes final transcription while allowing the capture layer to start a new session.
actor FinalizationQueue {
    typealias Work = @Sendable () async -> Void

    private var pending: [Work] = []
    private var isProcessing = false

    func enqueue(_ work: @escaping Work) {
        pending.append(work)
        guard !isProcessing else { return }

        isProcessing = true
        Task {
            await drain()
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let work = pending.removeFirst()
            await work()
        }
        isProcessing = false
    }
}
