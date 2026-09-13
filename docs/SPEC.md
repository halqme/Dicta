# Dicta

Status: MVP implementation contract
Target: macOS 26+
Language/runtime: Swift 6, Swift Concurrency
ASR: FluidAudio via Swift Package Manager

## 1. Product scope

Dicta is a local-first macOS menu bar utility for short-form voice input. It records from the system-default microphone, shows a low-latency live transcript as preview, performs a separate final transcription after the utterance is complete, and inserts only the final text.

The product deliberately does not implement meeting transcription, diarization, cloud inference, LLM rewriting, or audio archives in the MVP.

## 2. Surfaces

### Menu bar

The app normally runs as an accessory/menu-bar application with no main window and no Dock presence.

The menu exposes:

- Start/stop dictation
- Cancel current recording
- Open Fallback Editor
- Settings
- Quit

A user-configurable global shortcut is the normal activation path. The shortcut has one configured mode: Push to Talk or Toggle.

### Live Transcript HUD

While recording, a small non-editable, non-document HUD shows the preview transcript. It must not be treated as an insertion target and must not commit partial results into the active application.

### Fallback Editor

A single editable text window stores transcripts that cannot be inserted safely. New fallback results are appended in FIFO order, separated by a blank line. The editor uses the standard macOS text system and keeps the Writing Tools affordance visible.

### Settings

Settings contain activation mode, shortcut, default input language, preview model, final model, silence auto-finish controls, and local-history preference.

## 3. Recording interaction

### Push to Talk

- Shortcut key down: start recording.
- Shortcut key up: finish recording and enqueue finalization.
- Silence does not auto-finish PTT.
- Escape discards only the currently recording session.

### Toggle

- First shortcut press: start recording.
- Second shortcut press: finish recording and enqueue finalization.
- Optional silence auto-finish may finish the recording after N seconds with no detected speech.
- MVP default silence duration: 1.5 seconds.
- Voice activity detection should use FluidAudio/Silero VAD rather than an ad-hoc amplitude threshold.

## 4. ASR policy

### Preview ASR

- Preview is display-only.
- Only small streaming-capable models suitable for always-resident use are offered as preview models.
- The selected preview model is loaded at app startup and kept resident.
- Partial transcript changes may freely revise prior preview text.
- No preview text is inserted into another application.

### Final ASR

- The final result is the only result eligible for insertion.
- A streaming-capable model may also be selected as the final model; it is still treated as a final pass and its result is committed only after recording finishes.
- Model download happens when a model is selected/installed in Settings, not during first dictation.
- The selected final model starts loading/warming when recording starts.
- A loaded final model remains resident for 10 minutes after its latest use, then is cleaned up.
- Preview and final may use the same checkpoint, but Dicta does not share one stateful `StreamingAsrManager` across them because preview for session B may overlap finalization of session A. FluidAudio may share underlying Core ML resources internally; Dicta keeps decoder/session state independent.
- Keep one preview manager plus at most the currently selected final manager resident in normal operation.

## 5. Concurrency and queueing

Microphone capture and finalization are independent lanes.

- At most one recording is active at a time.
- Starting a new recording is allowed while prior sessions are queued, transcribing, or inserting.
- Final ASR jobs are processed FIFO and serially by one consumer.
- Do not run multiple heavy final-model inferences concurrently by default.
- A session captures its destination information when recording starts. Finalization never retargets the text field that happens to be focused later.
- Escape cancels only the active capture; it does not cancel sessions already handed to finalization.

Conceptual states for one session:

`recording -> queued -> transcribing -> delivering -> completed`

Alternate terminal paths:

`recording -> cancelled`

`delivering -> fallbackEditor`

## 6. Destination resolution and insertion

Resolve the destination once when recording starts.

### Preferred path: Accessibility API

When a writable text target can be represented reliably with Accessibility APIs:

- retain sufficient target identity and selection/caret information to insert after delayed finalization;
- replace the selected range when selection exists;
- otherwise insert at the captured caret;
- do not send partial preview text.

AX-backed sessions remain eligible for automatic insertion even if later recordings have begun.

### Secondary path: pasteboard simulated paste

When AX cannot provide a safe writable target, a single outstanding non-AX session may use a Cmd-V style insertion if the original application/focus context is still demonstrably safe.

The app must preserve the user's clipboard:

1. snapshot all relevant pasteboard items;
2. write the final transcript temporarily;
3. synthesize paste;
4. restore the previous pasteboard only if the pasteboard change count shows no third party changed it in the meantime.

Never restore stale clipboard contents over a newer user/application clipboard write.

The app must not forcibly activate an old application just to paste into it.

### Multiple outstanding non-AX sessions

If two or more non-AX sessions overlap in the outstanding queue/finalization period, the group is no longer eligible for best-effort paste insertion. Route all outstanding non-AX results in that overlap group to the single Fallback Editor in FIFO order.

This rule intentionally trades automation for predictable destination behavior.

### Final fallback

If AX insertion cannot be completed safely and paste insertion is not safely eligible, append the transcript to Fallback Editor and retain it in history.

Secure text inputs must not be bypassed.

## 7. History and privacy

- ASR inference is local; the app does not transmit recorded audio or transcripts to an external service.
- Raw captured audio exists only in memory for the current/finalizing session and is destroyed after finalization or cancellation.
- Transcript history is local and can be disabled.
- MVP retention policy: keep at most the newest 100 transcript items and remove items older than 7 days.
- History stores final text, timestamp, destination outcome, and optionally target application identity/name. It does not store audio.
- Dicta may fetch the public model-catalog JSON from its GitHub repository at startup and downloads model files only when the user installs a model from Settings. Catalog requests do not contain recorded audio or transcript text.

## 8. Model/language settings

The source of truth for model metadata is `Dicta/Resources/models.json`, not Swift source. The manifest contains a schema version, monotonic revision, model IDs, open language-code strings, roles, backend metadata, defaults, and coarse relative speed/accuracy ratings.

At startup Dicta uses the newer of the bundled catalog and the last-known-good cached remote catalog. It then checks the canonical catalog on GitHub. A newer valid revision is written atomically and takes effect on the next launch. Network failure, stale revisions, unknown schema versions, or invalid manifests leave the working catalog unchanged.

The catalog is allowed to describe more models and languages than the running app can execute. Runtime compatibility remains a binary capability: Settings exposes only entries whose backend and variant are supported by the current Dicta/FluidAudio build. This keeps catalog updates from creating selectable-but-nonfunctional models.

Dicta's user-facing input languages are currently Japanese and English. Catalog language codes are deliberately open strings, so entries may describe French, German, Chinese, Korean, and other languages without making older binaries fail to decode the manifest. The app presents only the intersection between catalog capabilities and app-supported input languages.

With FluidAudio 0.15.7, resident preview remains English-only Parakeet EOU 120M. Final-model support includes Cohere Transcribe, Parakeet TDT v2/v3/Japanese, Parakeet TDT-CTC 110M, Parakeet EOU, English Nemotron streaming tiers, and Parakeet Unified streaming/offline tiers. Other FluidAudio ASR families may be present in the catalog but stay hidden until Dicta implements their manager-specific adapter.

Speed and accuracy ratings are qualitative relative guidance for model selection, not claims that results from different hardware, languages, or benchmark datasets are numerically comparable.

## 9. Permissions

The app requires:

- Microphone access for AVFoundation capture.
- Accessibility permission for AX target resolution, direct insertion, and simulated paste where needed.

The Xcode target disables App Sandbox because cross-application AX control is a core capability. Hardened Runtime remains enabled, with the microphone audio-input entitlement and an `NSMicrophoneUsageDescription` generated into Info.plist.

Permission failures must leave the user with an understandable path to Settings rather than silently failing.

## 10. Non-goals for MVP

- Cloud ASR or cloud post-processing
- Automatic grammar/LLM rewrite before insertion
- Meeting recording
- Speaker diarization
- Audio-file transcription
- Multiple simultaneous microphone captures
- Concurrent heavy final ASR inference
- Per-app profiles
- Custom microphone-device selection
- Persistent audio history
- Forced focus switching to an earlier application

## 11. Implementation boundaries

Keep these responsibilities separate:

- `RecordingService`: microphone and in-memory PCM ownership.
- `ASRService`: FluidAudio model lifecycle and transcription.
- `ModelCatalogLoader`: bundled/cached/remote model-catalog selection and refresh.
- `ModelCatalog`: decoded model metadata, validation, and runtime-visible queries.
- `TargetResolver`: target captured at record start.
- `InputDeliveryService`: AX/pasteboard/fallback decision and delivery.
- `FinalizationQueue`: serial finalization consumer independent from capture.
- `SettingsStore`: durable preferences.
- `AppModel`: UI-owned observable state only.

UI-owned state is `@MainActor`. Audio/model/finalization work must not be placed on the main actor merely to silence concurrency diagnostics. Prefer actors and immutable `Sendable` session metadata at isolation boundaries.

## 12. MVP implementation status

Implemented in the initial Xcode project and subsequent catalog work:

1. Carbon global shortcut registration with pressed/released events for PTT, Toggle behavior, and Escape cancellation while recording.
2. `AVAudioEngine` system-default microphone capture with an `AsyncStream` of preview/VAD chunks while retaining lossless final PCM separately.
3. FluidAudio Parakeet EOU resident preview integration for English.
4. Final-model installation, recording-start warm-up, serial final inference, and actor-owned 10-minute eviction across the supported Cohere, Parakeet, Nemotron, and Unified adapters.
5. Silero streaming VAD silence auto-finish for Toggle mode.
6. AX target/selection capture at recording start and conservative delayed direct insertion.
7. Clipboard-preserving Cmd-V fallback with full pasteboard representation snapshots and `changeCount` race protection.
8. Non-AX overlap-group routing to one Fallback Editor.
9. Local JSON history persistence/pruning.
10. Non-activating AppKit HUD presentation and a standard editable Fallback Editor with Writing Tools affordance.
11. Bundled + remotely refreshable model catalog with last-known-good caching, open language codes, runtime capability filtering, and model speed/accuracy guidance.

Still required before shipping:

- Build and run on macOS 26 with the selected Xcode toolchain; this repository may have been edited in non-macOS environments where AppKit cannot be type-checked.
- Exercise TCC permission transitions (microphone, Accessibility/post-event) on a clean user account.
- End-to-end tests against representative native AppKit/SwiftUI, Chromium/Electron, browser, and secure-text targets.
- Profile model load time, memory residency, and ANE contention on supported Macs.
- Developer ID signing, notarization, update/distribution policy, and an application icon.
