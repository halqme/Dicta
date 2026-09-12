import Foundation
import Testing
@testable import Dicta

@Test
func historyRetentionRemovesExpiredItems() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let recent = TranscriptHistoryItem(
        id: UUID(),
        createdAt: now.addingTimeInterval(-60),
        text: "recent",
        destination: .accessibility
    )
    let old = TranscriptHistoryItem(
        id: UUID(),
        createdAt: now.addingTimeInterval(-(8 * 24 * 60 * 60)),
        text: "old",
        destination: .fallbackEditor
    )

    #expect(HistoryRetention.prune([old, recent], now: now) == [recent])
}
