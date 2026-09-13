# Dicta

Dicta is a deliberately small, local-first dictation utility for macOS 26 and later. It is a menu-bar app built with SwiftUI, narrow AppKit/Accessibility bridges, Swift Concurrency, and FluidAudio 0.15.7.

The name comes from *dicta* (the plural of *dictum*) and from stopping halfway through “dictation”.

See [`docs/SPEC.md`](docs/SPEC.md) for the product and concurrency contract.

## Requirements

- macOS 26+
- Xcode with Swift 6 support
- Apple Silicon recommended for FluidAudio/Core ML inference

## Project shape

Dicta is a normal Xcode macOS application target. Swift Package Manager is used only for the FluidAudio dependency; the application itself is not packaged as a SwiftPM executable.

FluidAudio is pinned to `0.15.7` in `Dicta.xcodeproj`.

## Build and run

Open `Dicta.xcodeproj`, select the `Dicta` scheme, choose **My Mac**, and Run.

The app target intentionally:

- targets macOS 26.0;
- uses Swift 6;
- runs as an `LSUIElement` menu-bar accessory app;
- disables App Sandbox because cross-application Accessibility insertion is a core feature;
- enables Hardened Runtime and the microphone audio-input entitlement;
- declares `NSMicrophoneUsageDescription`.

For distribution, use the normal Developer ID signing/notarization workflow rather than the Mac App Store sandbox.

## First run

1. Open Dicta Settings.
2. Grant Accessibility access.
3. Choose/install the final model. The default is Cohere Transcribe.
4. If using English live preview, choose/install a Parakeet EOU preview model.
5. If using Toggle + silence auto-finish, install the Silero speech detector.
6. Press the configured global shortcut (default `⌥Space`).

Microphone permission is requested by macOS on the first recording.

## Model catalog

Model metadata lives in `Dicta/Resources/models.json`, not in Swift source. The manifest describes model IDs, supported language codes, preview/final roles, backend metadata, defaults, and coarse 1–5 speed/accuracy ratings.

At launch Dicta uses the newer of the bundled manifest and the last-known-good cached manifest. It then checks the canonical `models.json` on this repository and atomically caches a newer valid `revision` for the next launch. A malformed, unsupported-schema, stale, or unavailable remote manifest never replaces the working catalog.

The catalog is deliberately broader than the current Dicta UI. It can describe FluidAudio models and languages that this binary does not yet have an adapter for. `ModelRuntimeCapabilities` filters Settings to backend/variant combinations this Dicta build can actually execute, so publishing a catalog entry cannot create a selectable-but-broken model.

Dicta itself currently exposes Japanese and English as input languages. Catalog language codes are open strings, so adding French, German, Chinese, or other model capabilities does not require older app binaries to understand or expose those languages.

Speed and accuracy values are qualitative relative ratings intended for model selection. They are not presented as directly comparable benchmark measurements across hardware, languages, or datasets.

Preview text is never inserted. Only a final pass can be delivered to another app.

## Privacy

ASR inference is local. Recorded PCM is kept only in memory until its finalization job completes. Transcript history is local JSON under Dicta's Application Support directory and is pruned to 100 items / 7 days. No audio history is persisted.

Dicta does make network requests for two narrow purposes: checking the public model-catalog metadata on this GitHub repository at launch, and downloading a model from FluidAudio's model source when the user explicitly installs it in Settings. Recorded audio and transcript text are not sent with the catalog request.
