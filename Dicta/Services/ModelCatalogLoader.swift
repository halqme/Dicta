import Foundation

/// Loads the bundled model catalog, prefers the last-known-good remote copy at startup, and
/// refreshes that cache for the next launch. Catalog updates deliberately do not mutate the live
/// settings/ASR graph while Dicta is running.
nonisolated enum ModelCatalogLoader {
    static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/halqme/Dicta/main/Dicta/Resources/models.json"
    )!

    private static let cacheFileName = "models.json"

    static func loadBundledCatalog(bundle: Bundle = .main) -> ModelCatalog {
        guard let url = bundle.url(forResource: "models", withExtension: "json") else {
            preconditionFailure("Dicta is missing its bundled models.json catalog.")
        }

        do {
            return try decodeCatalog(Data(contentsOf: url))
        } catch {
            preconditionFailure("Dicta's bundled models.json is invalid: \(error.localizedDescription)")
        }
    }

    static func loadStartupCatalog() -> ModelCatalog {
        if let cached = loadCachedCatalog() {
            return cached
        }
        return loadBundledCatalog()
    }

    /// Fetch and validate the canonical manifest. A failed request, unsupported schema, or invalid
    /// catalog leaves the previous cache untouched.
    static func refreshCache() async {
        var request = URLRequest(
            url: remoteURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            _ = try decodeCatalog(data)
            let destination = try cacheURL(createParent: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            // Remote catalog refresh is best-effort. The bundled or last-known-good catalog remains
            // authoritative until a complete, valid replacement has been written atomically.
        }
    }

    static func decodeCatalog(_ data: Data) throws -> ModelCatalog {
        try JSONDecoder().decode(ModelCatalog.self, from: data)
    }

    private static func loadCachedCatalog() -> ModelCatalog? {
        do {
            let url = try cacheURL(createParent: false)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try decodeCatalog(Data(contentsOf: url))
        } catch {
            return nil
        }
    }

    private static func cacheURL(createParent: Bool) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Dicta", isDirectory: true)
        if createParent {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory.appendingPathComponent(cacheFileName, isDirectory: false)
    }
}
