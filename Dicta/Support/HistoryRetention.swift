import Foundation

nonisolated enum HistoryRetention {
    static let maximumCount = 100
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func prune(_ items: [TranscriptHistoryItem], now: Date = .now) -> [TranscriptHistoryItem] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        return items
            .filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maximumCount)
            .map { $0 }
    }
}
