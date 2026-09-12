import Foundation
import Testing
@testable import Dicta

@Test
func modelCatalogDecodesJSONManifest() throws {
    let json = """
    {
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
          "defaultRoles": ["preview"]
        },
        {
          "id": "json-final",
          "name": "JSON Final",
          "languages": ["ja", "en"],
          "roleDetails": [
            {
              "role": "final",
              "detail": "A final model supplied by a manifest"
            }
          ],
          "backend": {
            "kind": "cohere-transcribe"
          },
          "defaultRoles": ["final"]
        }
      ]
    }
    """

    let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))

    #expect(catalog.previewModels.map(\.id) == ["json-preview"])
    #expect(catalog.finalModels.map(\.id) == ["json-final"])
    #expect(Set(catalog.models.map(\.id)).count == catalog.models.count)
    #expect(catalog.previewModels[0].backend.kind == .streaming)
    #expect(catalog.previewModels[0].backend.variantID == "parakeet-eou-160ms")
    #expect(catalog.previewModels[0].detail(for: .preview) == "A preview model supplied by a manifest")
    #expect(catalog.finalModels[0].backend == .cohereTranscribe)
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
func builtInCatalogPreservesCurrentDefaultsAndLanguagePolicy() {
    let catalog = ModelCatalog.builtIn

    #expect(catalog.defaultPreviewOption(for: .english)?.id == "parakeet-eou-320ms")
    #expect(catalog.defaultFinalOption(for: .japanese)?.id == "cohere-transcribe")
    #expect(catalog.previewOptions(for: .japanese).isEmpty)
    #expect(catalog.finalOptions(for: .japanese).map(\.id) == ["cohere-transcribe", "parakeet-ja"])
    #expect(catalog.finalModels.filter { $0.backend.kind == .streaming }.map(\.id) == [
        "parakeet-eou-160ms",
        "parakeet-eou-320ms",
        "parakeet-eou-1280ms",
    ])
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
