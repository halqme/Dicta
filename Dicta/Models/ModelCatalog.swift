import Foundation

/// Runtime-independent backend information for one model definition.
///
/// The definition is deliberately made from Codable values rather than FluidAudio types. The
/// built-in catalog is the current source, but the same shape can be decoded from a future JSON
/// manifest without changing the settings or ASR boundaries.
nonisolated struct ASRModelBackend: Codable, Hashable, Sendable {
    /// An open backend identifier. The catalog can preserve backends that this app version does
    /// not have an adapter for yet; ASRService rejects those only when the model is used.
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
    let languages: Set<InputLanguage>
    /// One physical model can be exposed in more than one app role. Keeping role-specific details
    /// here avoids duplicating the backend definition when preview and final share a checkpoint.
    let roleDetails: [ASRModelRoleDetail]
    let backend: ASRModelBackend
    let defaultRoles: Set<Role>

    func supports(_ language: InputLanguage) -> Bool {
        languages.contains(language)
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

/// Compatibility catalog used by the UI and the FluidAudio adapter.
///
/// Keeping the complete definitions in one value is the seam for replacing `builtIn` with a
/// decoded JSON catalog later. Consumers must not need to know where the definitions came from.
nonisolated struct ModelCatalog: Codable, Sendable {
    let models: [ASRModelOption]

    init(models: [ASRModelOption]) {
        self.models = models
    }

    static let builtIn = Self(models: [
        ASRModelOption(
            id: "parakeet-eou-160ms",
            name: "Parakeet EOU 120M · 160 ms",
            languages: [.english],
            roleDetails: [
                ASRModelRoleDetail(
                    role: .preview,
                    detail: "Lowest latency, English only"
                ),
                ASRModelRoleDetail(
                    role: .final,
                    detail: "Lowest-latency streaming final pass, English only"
                ),
            ],
            backend: .streaming(variantID: "parakeet-eou-160ms"),
            defaultRoles: []
        ),
        ASRModelOption(
            id: "parakeet-eou-320ms",
            name: "Parakeet EOU 120M · 320 ms",
            languages: [.english],
            roleDetails: [
                ASRModelRoleDetail(
                    role: .preview,
                    detail: "Balanced realtime preview, English only"
                ),
                ASRModelRoleDetail(
                    role: .final,
                    detail: "Small streaming model used as a final pass after recording"
                ),
            ],
            backend: .streaming(variantID: "parakeet-eou-320ms"),
            defaultRoles: [.preview]
        ),
        ASRModelOption(
            id: "parakeet-eou-1280ms",
            name: "Parakeet EOU 120M · 1280 ms",
            languages: [.english],
            roleDetails: [
                ASRModelRoleDetail(
                    role: .preview,
                    detail: "Higher latency, English only"
                ),
                ASRModelRoleDetail(
                    role: .final,
                    detail: "Higher-latency streaming final pass, English only"
                ),
            ],
            backend: .streaming(variantID: "parakeet-eou-1280ms"),
            defaultRoles: []
        ),
        ASRModelOption(
            id: "cohere-transcribe",
            name: "Cohere Transcribe",
            languages: [.japanese, .english],
            roleDetails: [
                ASRModelRoleDetail(
                    role: .final,
                    detail: "High-accuracy multilingual final transcription"
                ),
            ],
            backend: .cohereTranscribe,
            defaultRoles: [.final]
        ),
        ASRModelOption(
            id: "parakeet-ja",
            name: "Parakeet TDT Japanese",
            languages: [.japanese],
            roleDetails: [
                ASRModelRoleDetail(
                    role: .final,
                    detail: "Japanese-only 0.6B final model"
                ),
            ],
            backend: .parakeet(version: "tdt-ja"),
            defaultRoles: []
        ),
        ASRModelOption(
            id: "parakeet-v3",
            name: "Parakeet TDT v3",
            languages: [.english],
            roleDetails: [
                ASRModelRoleDetail(
                    role: .final,
                    detail: "0.6B multilingual model; Dicta exposes it for English"
                ),
            ],
            backend: .parakeet(version: "v3"),
            defaultRoles: []
        ),
        ASRModelOption(
            id: "parakeet-v2",
            name: "Parakeet TDT v2",
            languages: [.english],
            roleDetails: [
                ASRModelRoleDetail(
                    role: .final,
                    detail: "0.6B English-only model"
                ),
            ],
            backend: .parakeet(version: "v2"),
            defaultRoles: []
        ),
    ])

    var previewModels: [ASRModelOption] {
        models.filter { $0.supports(.preview) }
    }

    var finalModels: [ASRModelOption] {
        models.filter { $0.supports(.final) }
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

    func previewOption(id: String) -> ASRModelOption? {
        guard let model = model(id: id), model.supports(.preview) else { return nil }
        return model
    }

    func finalOption(id: String) -> ASRModelOption? {
        guard let model = model(id: id), model.supports(.final) else { return nil }
        return model
    }

    func defaultPreviewOption(for language: InputLanguage) -> ASRModelOption? {
        defaultOption(in: previewOptions(for: language), role: .preview)
    }

    func defaultFinalOption(for language: InputLanguage) -> ASRModelOption? {
        defaultOption(in: finalOptions(for: language), role: .final)
    }

    private func defaultOption(
        in options: [ASRModelOption],
        role: ASRModelOption.Role
    ) -> ASRModelOption? {
        options.first(where: { $0.isDefault(for: role) }) ?? options.first
    }

    private enum ValidationError: Error, LocalizedError {
        case emptyCatalog
        case emptyModelID
        case duplicateModelID(String)
        case emptyRoleDetails(String)
        case duplicateRole(String)
        case defaultRoleNotExposed(String)
        case previewBackendMustBeStreaming(String)
        case emptyBackendKind(String)
        case backendVariantRequired(String)
        case cohereBackendCannotHaveVariant(String)
        case multipleDefaults(role: ASRModelOption.Role, firstModelID: String, secondModelID: String)

        var errorDescription: String? {
            switch self {
            case .emptyCatalog:
                "The model catalog must contain at least one model."
            case .emptyModelID:
                "A model catalog entry must have a non-empty ID."
            case .duplicateModelID(let modelID):
                "The model catalog contains duplicate ID '\(modelID)'."
            case .emptyRoleDetails(let modelID):
                "The model '\(modelID)' has no exposed role."
            case .duplicateRole(let modelID):
                "The model '\(modelID)' contains duplicate role details."
            case .defaultRoleNotExposed(let modelID):
                "The model '\(modelID)' marks a role as default without exposing it."
            case .previewBackendMustBeStreaming(let modelID):
                "The preview model '\(modelID)' must use the streaming backend."
            case .emptyBackendKind(let modelID):
                "The backend kind for model '\(modelID)' must not be empty."
            case .backendVariantRequired(let modelID):
                "The backend variant for model '\(modelID)' is missing."
            case .cohereBackendCannotHaveVariant(let modelID):
                "The Cohere backend for model '\(modelID)' cannot have a variant."
            case .multipleDefaults(let role, let firstModelID, let secondModelID):
                "The role '\(role.rawValue)' has multiple defaults: '\(firstModelID)' and '\(secondModelID)'."
            }
        }
    }

    private static func validate(_ models: [ASRModelOption]) throws {
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
            if model.supports(.preview), (isCohere || isParakeet) {
                throw ValidationError.previewBackendMustBeStreaming(model.id)
            }
            if isCohere, model.backend.variantID != nil {
                throw ValidationError.cohereBackendCannotHaveVariant(model.id)
            }
            if (isParakeet || isStreaming), model.backend.variantID == nil {
                throw ValidationError.backendVariantRequired(model.id)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let models = try container.decode([ASRModelOption].self, forKey: .models)
        try Self.validate(models)
        self.models = models
    }
}
