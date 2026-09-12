import Foundation

actor HistoryStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.fileURL = base
                .appendingPathComponent("Dicta", isDirectory: true)
                .appendingPathComponent("history.json", isDirectory: false)
        }
    }

    func load() throws -> [TranscriptHistoryItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let items = try JSONDecoder().decode([TranscriptHistoryItem].self, from: data)
        let retained = HistoryRetention.prune(items)
        if retained != items {
            try save(retained)
        }
        return retained
    }

    @discardableResult
    func append(_ item: TranscriptHistoryItem) throws -> [TranscriptHistoryItem] {
        var items = try load()
        items.insert(item, at: 0)
        items = HistoryRetention.prune(items)
        try save(items)
        return items
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func save(_ items: [TranscriptHistoryItem]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}
