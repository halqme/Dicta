import Foundation

/// Open language code used by the remote model catalog.
///
/// Dicta's user-facing input languages are intentionally a smaller closed set. Keeping catalog
/// language codes open means a newer manifest can describe languages an older Dicta binary does
/// not expose without making the whole manifest undecodable.
nonisolated struct ModelLanguageCode: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let japanese = Self(rawValue: "ja")
    static let english = Self(rawValue: "en")
}

/// Qualitative, catalog-maintained comparison values. These are deliberately coarse rather than
/// pretending that benchmark numbers from different hardware/datasets are directly comparable.
nonisolated struct ASRModelPerformance: Codable, Hashable, Sendable {
    let speed: Int
    let accuracy: Int

    var speedDisplayName: String {
        switch speed {
        case 1: "Slow"
        case 2: "Moderate"
        case 3: "Balanced"
        case 4: "Fast"
        case 5: "Very fast"
        default: "Unknown"
        }
    }

    var accuracyDisplayName: String {
        switch accuracy {
        case 1: "Basic"
        case 2: "Fair"
        case 3: "Good"
        case 4: "High"
        case 5: "Very high"
        default: "Unknown"
        }
    }

    var summary: String {
        "Speed: \(speedDisplayName) · Accuracy: \(accuracyDisplayName)"
    }
}

/// Runtime-independent backend information for one model definition.
///
/// Backend identifiers are open strings. A remote catalog may therefore preserve definitions for
/// a newer Dicta/FluidAudio combination while this binary simply hides entries it cannot execute.
nonisolated struct ASRModelBackend: Codable, Hashable, Sendable {
    struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        static let cohereTranscribe = Self(rawValue: "cohere-transcribe")
        static let parakeet = Self(rawValue: "parakeet")
        static let streaming = Self(rawValue: "streaming")
    }

    let kind: Kind
    /// Backend-specific identifier. Its meaning belongs to the adapter named by `kind`.
    let variantID: String?

    init(kind: Kind, variantID: String? = nil) {
        self.kind = kind
        self.variantID = variantID
    }

    init(kind: String, variantID: String? = nil) {
        self.init(kind: Kind(rawValue: kind), variantID: variantID)
    }

    static let cohereTranscribe = Self(kind: .cohereTranscribe)

    static func parakeet(version: String) -> Self {
        Self(kind: .parakeet, variantID: version)
    }

    static func streaming(variantID: String) -> Self {
        Self(kind: .streaming, variantID: variantID)
    }
}

nonisolated struct ASRModelOption: Identifiable, Hashable, Sendable, Codable {
    enum Role: String, Codable, Hashable, Sendable {
        case preview
        case final
    }

    let id: String
    let name: String
    let languages: Set<ModelLanguageCode>
    /// One physical model can be exposed in more than one app role. Keeping role-specific details
    /// here avoids duplicating the backend definition when preview and final share a checkpoint.
    let roleDetails: [ASRModelRoleDetail]
    let backend: ASRModelBackend
    let defaultRoles: Set<Role>
    let performance: ASRModelPerformance?

    init(
        id: String,
        name: String,
        languages: Set<ModelLanguageCode>,
        roleDetails: [ASRModelRoleDetail],
        backend: ASRModelBackend,
        defaultRoles: Set<Role>,
        performance: ASRModelPerformance? = nil
    ) {
        self.id = id
        self.name = name
        self.languages = languages
        self.roleDetails = roleDetails
        self.backend = backend
        self.defaultRoles = defaultRoles
        self.performance = performance
    }

    func supports(_ language: InputLanguage) -> Bool {
        languages.contains(ModelLanguageCode(rawValue: language.rawValue))
    }

    func supports(_ role: Role) -> Bool {
        roleDetails.contains { $0.role == role }
    }

    func detail(for role: Role) -> String? {
        roleDetails.first(where: { $0.role == role })?.detail
    }

    func isDefault(for role: Role) -> Bool {
        defaultRoles.contains(role)
    }
}

nonisolated struct ASRModelRoleDetail: Codable, Hashable, Sendable {
    let role: ASRModelOption.Role
    let detail: String
}

/// Capabilities compiled into this Dicta binary.
///
/// The remote manifest describes FluidAudio's wider model universe. This filter is the safety
/// boundary that prevents a new catalog entry from becoming selectable until this binary has an
/// adapter for its backend/variant.
nonisolated struct ModelRuntimeCapabilities: Sendable {
    static let current = Self()

    private static let parakeetVariants: Set<String> = [
        "v2",
        "v3",
        "tdt-ctc-110m",
        "tdt-ja",
    ]

    private static let streamingVariants: Set<String> = [
        "parakeet-eou-160ms",
        "parakeet-eou-320ms",
        "parakeet-eou-1280ms",
        "nemotron-560ms",
        "nemotron-1120ms",
        "nemotron-2240ms",
        "parakeet-unified-320ms",
        "parakeet-unified-640ms",
        "parakeet-unified-1120ms",
        "parakeet-unified-2080ms",
        "parakeet-unified-offline-15s",
    ]

    func supports(_ option: ASRModelOption) -> Bool {
        if option.backend.kind == .cohereTranscribe {
            return option.backend.variantID == nil
        }
        if option.backend.kind == .parakeet {
            return option.backend.variantID.map(Self.parakeetVariants.contains) ?? false
        }
        if option.backend.kind == .streaming {
            return option.backend.variantID.map(Self.streamingVariants.contains) ?? false
        }
        return false
    }
}

/// Compatibility catalog used by the UI and ASR adapter.
///
/// Definitions come from JSON rather than Swift. A last-known-good remote manifest can replace the
/// bundled manifest on the next launch without changing consumers of this type.
nonisolated struct ModelCatalog: Codable, Sendable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let revision: Int
    let models: [ASRModelOption]

    init(
        schemaVersion: Int = Self.supportedSchemaVersion,
        revision: Int = 0,
        models: [ASRModelOption]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.models = models
    }

    /// Bundled fallback used by tests and explicit service construction. Normal app startup goes
    /// through `ModelCatalogLoader.loadStartupCatalog()` so a cached remote catalog can win.
    static var builtIn: Self {
        ModelCatalogLoader.loadBundledCatalog()
    }

    var previewModels: [ASRModelOption] {
        models.filter { $0.supports(.preview) }
    }

    var finalModels: [ASRModelOption] {
        models.filter { $0.supports(.final) }
    }

    var runnablePreviewModels: [ASRModelOption] {
        previewModels.filter(ModelRuntimeCapabilities.current.supports)
    }

    var runnableFinalModels: [ASRModelOption] {
        finalModels.filter(ModelRuntimeCapabilities.current.supports)
    }

    func model(id: String) -> ASRModelOption? {
        models.first { $0.id == id }
    }

    func previewOptions(for language: InputLanguage) -> [ASRModelOption] {
        previewModels.filter { $0.supports(language) }
    }

    func finalOptions(for language: InputLanguage) -> [ASRModelOption] {
        finalModels.filter { $0.supports(language) }
    }

    func runnablePreviewOptions(for language: InputLanguage) -> [ASRModelOption] {
        runnablePreviewModels.filter { $0.supports(language) }
    }

    func runnableFinalOptions(for language: InputLanguage) -> [ASRModelOption] {
        runnableFinalModels.filter { $0.supports(language) }
    }

    func previewOption(id: String) -> ASRModelOption? {
        guard let model = model(id: id), model.supports(.preview) else { return nil }
        return model
    }

    func finalOption(id: String) -> ASRModelOption? {
        guard let model = model(id: id), model.supports(.final) else { return nil }
        return model
    }

    func defaultPreviewOption(for language: InputLanguage) -> ASRModelOption? {
        defaultOption(in: runnablePreviewOptions(for: language), role: .preview)
    }

    func defaultFinalOption(for language: InputLanguage) -> ASRModelOption? {
        defaultOption(in: runnableFinalOptions(for: language), role: .final)
    }

    private func defaultOption(
        in options: [ASRModelOption],
        role: ASRModelOption.Role
    ) -> ASRModelOption? {
        options.first(where: { $0.isDefault(for: role) }) ?? options.first
    }

    private enum ValidationError: Error, LocalizedError {
        case unsupportedSchemaVersion(Int)
        case emptyCatalog
        case emptyModelID
        case duplicateModelID(String)
        case emptyLanguages(String)
        case emptyRoleDetails(String)
        case duplicateRole(String)
        case defaultRoleNotExposed(String)
        case emptyBackendKind(String)
        case backendVariantRequired(String)
        case cohereBackendCannotHaveVariant(String)
        case invalidPerformance(modelID: String)
        case multipleDefaults(role: ASRModelOption.Role, firstModelID: String, secondModelID: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                "Unsupported model catalog schema version \(version)."
            case .emptyCatalog:
                "The model catalog must contain at least one model."
            case .emptyModelID:
                "A model catalog entry must have a non-empty ID."
            case .duplicateModelID(let modelID):
                "The model catalog contains duplicate ID '\(modelID)'."
            case .emptyLanguages(let modelID):
                "The model '\(modelID)' has no declared language."
            case .emptyRoleDetails(let modelID):
                "The model '\(modelID)' has no exposed role."
            case .duplicateRole(let modelID):
                "The model '\(modelID)' contains duplicate role details."
            case .defaultRoleNotExposed(let modelID):
                "The model '\(modelID)' marks a role as default without exposing it."
            case .emptyBackendKind(let modelID):
                "The backend kind for model '\(modelID)' must not be empty."
            case .backendVariantRequired(let modelID):
                "The backend variant for model '\(modelID)' is missing."
            case .cohereBackendCannotHaveVariant(let modelID):
                "The Cohere backend for model '\(modelID)' cannot have a variant."
            case .invalidPerformance(let modelID):
                "The model '\(modelID)' has speed/accuracy outside the 1...5 range."
            case .multipleDefaults(let role, let firstModelID, let secondModelID):
                "The role '\(role.rawValue)' has multiple defaults: '\(firstModelID)' and '\(secondModelID)'."
            }
        }
    }

    private static func validate(
        schemaVersion: Int,
        models: [ASRModelOption]
    ) throws {
        guard schemaVersion == supportedSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !models.isEmpty else { throw ValidationError.emptyCatalog }

        var modelIDs = Set<String>()
        var defaultModelIDs: [ASRModelOption.Role: String] = [:]
        for model in models {
            guard !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyModelID
            }
            guard modelIDs.insert(model.id).inserted else {
                throw ValidationError.duplicateModelID(model.id)
            }
            guard !model.languages.isEmpty else {
                throw ValidationError.emptyLanguages(model.id)
            }

            guard !model.roleDetails.isEmpty else {
                throw ValidationError.emptyRoleDetails(model.id)
            }
            var roles = Set<ASRModelOption.Role>()
            for roleDetail in model.roleDetails {
                guard roles.insert(roleDetail.role).inserted else {
                    throw ValidationError.duplicateRole(model.id)
                }
            }
            guard model.defaultRoles.isSubset(of: roles) else {
                throw ValidationError.defaultRoleNotExposed(model.id)
            }
            for role in model.defaultRoles {
                if let firstModelID = defaultModelIDs[role] {
                    throw ValidationError.multipleDefaults(
                        role: role,
                        firstModelID: firstModelID,
                        secondModelID: model.id
                    )
                }
                defaultModelIDs[role] = model.id
            }

            guard !model.backend.kind.rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            else {
                throw ValidationError.emptyBackendKind(model.id)
            }
            if let variantID = model.backend.variantID,
               variantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.backendVariantRequired(model.id)
            }

            let isCohere = model.backend.kind == .cohereTranscribe
            let isParakeet = model.backend.kind == .parakeet
            let isStreaming = model.backend.kind == .streaming
            if isCohere, model.backend.variantID != nil {
                throw ValidationError.cohereBackendCannotHaveVariant(model.id)
            }
            if (isParakeet || isStreaming), model.backend.variantID == nil {
                throw ValidationError.backendVariantRequired(model.id)
            }

            if let performance = model.performance {
                guard (1...5).contains(performance.speed),
                      (1...5).contains(performance.accuracy)
                else {
                    throw ValidationError.invalidPerformance(modelID: model.id)
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.supportedSchemaVersion
        let revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        let models = try container.decode([ASRModelOption].self, forKey: .models)
        try Self.validate(schemaVersion: schemaVersion, models: models)
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.models = models
    }
}
