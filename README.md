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

## Current model policy

- Japanese final: Cohere Transcribe or Parakeet TDT Japanese.
- English final: Cohere Transcribe, Parakeet TDT v2/v3, or the small Parakeet EOU streaming model used as a final pass.
- English preview: Parakeet EOU 120M (160/320/1280 ms).
- Japanese preview: disabled in FluidAudio 0.15.7 because the available Japanese streaming option is not a small always-resident model.

Preview text is never inserted. Only a final pass can be delivered to another app.

## Privacy

Recorded PCM is kept only in memory until its finalization job completes. Transcript history is local JSON under Dicta's Application Support directory and is pruned to 100 items / 7 days. No audio history is persisted.
