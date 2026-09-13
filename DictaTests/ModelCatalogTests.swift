import Foundation
import Testing
@testable import Dicta

@Test
func modelCatalogDecodesJSONManifest() throws {
    let json = """
    {
      "schemaVersion": 1,
      "revision": 7,
      "models": [
        {
          "id": "json-preview",
          "name": "JSON Preview",
          "languages": ["en"],
          "roleDetails": [
            {
              "role": "preview",
              "detail": "A preview model supplied by a manifest"
            }
          ],
          "backend": {
            "kind": "streaming",
            "variantID": "parakeet-eou-160ms"
          },
          "defaultRoles": ["preview"],
          "performance": {
            "speed": 5,
            "accuracy": 3
          }
        },
        {
          "id": "json-final",
          "name": "JSON Final",
          "languages": ["ja", "en", "fr"],
          "roleDetails": [
            {
              "role": "final",
              "detail": "A final model supplied by a manifest"
            }
          ],
          "backend": {
            "kind": "cohere-transcribe"
          },
          "defaultRoles": ["final"],
          "performance": {
            "speed": 2,
            "accuracy": 5
          }
        }
      ]
    }
    """

    let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))

    #expect(catalog.schemaVersion == 1)
    #expect(catalog.revision == 7)
    #expect(catalog.previewModels.map(\.id) == ["json-preview"])
    #expect(catalog.finalModels.map(\.id) == ["json-final"])
    #expect(Set(catalog.models.map(\.id)).count == catalog.models.count)
    #expect(catalog.previewModels[0].backend.kind == .streaming)
    #expect(catalog.previewModels[0].backend.variantID == "parakeet-eou-160ms")
    #expect(catalog.previewModels[0].detail(for: .preview) == "A preview model supplied by a manifest")
    #expect(catalog.previewModels[0].performance?.speed == 5)
    #expect(catalog.finalModels[0].backend == .cohereTranscribe)
    #expect(catalog.finalModels[0].languages.contains(ModelLanguageCode(rawValue: "fr")))
    #expect(catalog.defaultPreviewOption(for: .english)?.id == "json-preview")
    #expect(catalog.defaultFinalOption(for: .japanese)?.id == "json-final")
}

@Test
func modelCatalogRejectsDuplicateIDsWhenDecoded() throws {
    let model = ASRModelOption(
        id: "duplicate",
        name: "Duplicate",
        languages: [.english],
        roleDetails: [ASRModelRoleDetail(role: .final, detail: "Final")],
        backend: .cohereTranscribe,
        defaultRoles: [.final]
    )
    let data = try JSONEncoder().encode(ModelCatalog(models: [model, model]))
    var didThrow = false

    do {
        _ = try JSONDecoder().decode(ModelCatalog.self, from: data)
    } catch {
        didThrow = true
    }

    #expect(didThrow)
}

@Test
func modelCatalogPreservesUnknownBackendMetadataWhenDecoded() throws {
    let model = ASRModelOption(
        id: "whisper-large-v3",
        name: "Whisper Large v3",
        languages: [.english],
        roleDetails: [ASRModelRoleDetail(role: .final, detail: "External backend")],
        backend: ASRModelBackend(kind: "whisper", variantID: "large-v3"),
        defaultRoles: [.final]
    )
    let data = try JSONEncoder().encode(ModelCatalog(models: [model]))
    let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)

    #expect(catalog.finalOption(id: "whisper-large-v3")?.backend.kind.rawValue == "whisper")
    #expect(catalog.finalOption(id: "whisper-large-v3")?.backend.variantID == "large-v3")
}

@Test
func bundledCatalogPreservesDefaultsAndSeparatesCatalogFromRuntimeCapabilities() {
    let catalog = ModelCatalog.builtIn

    #expect(catalog.models.count >= 20)
    #expect(catalog.defaultPreviewOption(for: .english)?.id == "parakeet-eou-320ms")
    #expect(catalog.defaultFinalOption(for: .japanese)?.id == "cohere-transcribe")
    #expect(catalog.runnablePreviewOptions(for: .japanese).isEmpty)

    let runnableJapanese = Set(catalog.runnableFinalOptions(for: .japanese).map(\.id))
    #expect(runnableJapanese == ["cohere-transcribe", "parakeet-ja"])

    #expect(catalog.finalOptions(for: .japanese).contains { $0.id == "sensevoice-small" })
    #expect(!catalog.runnableFinalOptions(for: .japanese).contains { $0.id == "sensevoice-small" })
    #expect(catalog.finalOptions(for: .english).contains { $0.id == "parakeet-tdt-ctc-110m" })
    #expect(!catalog.runnableFinalOptions(for: .english).contains { $0.id == "parakeet-tdt-ctc-110m" })

    #expect(catalog.model(id: "cohere-transcribe")?.performance?.accuracy == 5)
    #expect(catalog.model(id: "parakeet-eou-160ms")?.performance?.speed == 5)
}

@Test
@MainActor
func settingsUseDefaultsFromInjectedCatalog() {
    let suiteName = "ModelCatalogTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let catalog = ModelCatalog(models: [
        ASRModelOption(
            id: "json-preview",
            name: "JSON Preview",
            languages: [.japanese, .english],
            roleDetails: [ASRModelRoleDetail(role: .preview, detail: "Preview")],
            backend: .streaming(variantID: "parakeet-eou-160ms"),
            defaultRoles: [.preview]
        ),
        ASRModelOption(
            id: "json-final",
            name: "JSON Final",
            languages: [.japanese, .english],
            roleDetails: [ASRModelRoleDetail(role: .final, detail: "Final")],
            backend: .cohereTranscribe,
            defaultRoles: [.final]
        ),
    ])

    let settings = SettingsStore(defaults: defaults, modelCatalog: catalog)

    #expect(settings.previewModelID == "json-preview")
    #expect(settings.finalModelID == "json-final")
    #expect(settings.selectedPreviewOption?.detail(for: .preview) == "Preview")
    #expect(settings.selectedFinalOption?.detail(for: .final) == "Final")
}

@Test
@MainActor
func settingsHideCatalogModelsThisBinaryCannotRun() {
    let suiteName = "ModelCatalogTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let catalog = ModelCatalog(models: [
        ASRModelOption(
            id: "unsupported-new-backend",
            name: "Unsupported",
            languages: [.japanese],
            roleDetails: [ASRModelRoleDetail(role: .final, detail: "Future adapter")],
            backend: ASRModelBackend(kind: "future-backend", variantID: "v1"),
            defaultRoles: []
        ),
        ASRModelOption(
            id: "supported-final",
            name: "Supported",
            languages: [.japanese],
            roleDetails: [ASRModelRoleDetail(role: .final, detail: "Current adapter")],
            backend: .cohereTranscribe,
            defaultRoles: [.final]
        ),
    ])

    let settings = SettingsStore(defaults: defaults, modelCatalog: catalog)

    #expect(settings.finalOptions.map(\.id) == ["supported-final"])
    #expect(settings.finalModelID == "supported-final")
}

@Test
func asrServiceUsesInjectedCatalogForValidation() async {
    let catalog = ModelCatalog(models: [
        ASRModelOption(
            id: "json-preview",
            name: "JSON Preview",
            languages: [.english],
            roleDetails: [ASRModelRoleDetail(role: .preview, detail: "Preview")],
            backend: .streaming(variantID: "parakeet-eou-160ms"),
            defaultRoles: [.preview]
        ),
    ])
    let service = ASRService(modelCatalog: catalog)
    var error: ASRServiceError?

    do {
        try await service.preparePreviewModelIfNeeded(modelID: "not-in-catalog")
    } catch let serviceError as ASRServiceError {
        error = serviceError
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(
        error == .unsupportedPreviewModel(
            modelID: "not-in-catalog",
            supportedModelIDs: ["json-preview"]
        )
    )
}

@Test
func asrServiceUsesCatalogLanguageMetadataForValidModelIDs() async {
    let catalog = ModelCatalog(models: [
        ASRModelOption(
            id: "json-final",
            name: "JSON Final",
            languages: [.japanese],
            roleDetails: [ASRModelRoleDetail(role: .final, detail: "Final")],
            backend: .cohereTranscribe,
            defaultRoles: [.final]
        ),
    ])
    let service = ASRService(modelCatalog: catalog)
    var error: ASRServiceError?

    do {
        try await service.preflightFinalModel(modelID: "json-final", language: .english)
    } catch let serviceError as ASRServiceError {
        error = serviceError
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(error == .unsupportedLanguage(modelID: "json-final", language: .english))
}

@Test
func asrServiceRejectsUnknownBackendAfterResolvingCatalogID() async {
    let catalog = ModelCatalog(models: [
        ASRModelOption(
            id: "whisper-large-v3",
            name: "Whisper Large v3",
            languages: [.english],
            roleDetails: [ASRModelRoleDetail(role: .final, detail: "External backend")],
            backend: ASRModelBackend(kind: "whisper", variantID: "large-v3"),
            defaultRoles: [.final]
        ),
    ])
    let service = ASRService(modelCatalog: catalog)
    var error: ASRServiceError?

    do {
        try await service.preflightFinalModel(modelID: "whisper-large-v3", language: .english)
    } catch let serviceError as ASRServiceError {
        error = serviceError
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(error == .unsupportedFinalModel(modelID: "whisper-large-v3"))
}
