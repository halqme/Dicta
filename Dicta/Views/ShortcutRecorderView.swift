import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotKeyConfiguration

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.beginRecordingShortcut(_:))
        button.onCapture = { configuration in
            context.coordinator.parent.shortcut = configuration
        }
        button.updateTitle(for: shortcut)
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        context.coordinator.parent = self
        nsView.onCapture = { configuration in
            context.coordinator.parent.shortcut = configuration
        }
        if !nsView.isRecordingShortcut {
            nsView.updateTitle(for: shortcut)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ShortcutRecorderView

        init(parent: ShortcutRecorderView) {
            self.parent = parent
        }

        @objc func beginRecordingShortcut(_ sender: ShortcutRecorderButton) {
            sender.beginRecordingShortcut()
        }
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onCapture: ((HotKeyConfiguration) -> Void)?
    private(set) var isRecordingShortcut = false

    override var acceptsFirstResponder: Bool { true }

    func beginRecordingShortcut() {
        isRecordingShortcut = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)
    }

    func updateTitle(for shortcut: HotKeyConfiguration) {
        title = Self.displayString(for: shortcut)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            isRecordingShortcut = false
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return
        }

        let key = Self.keyName(for: event)
        let configuration = HotKeyConfiguration(
            keyCode: UInt32(event.keyCode),
            modifierFlagsRawValue: modifiers.rawValue,
            displayKey: key
        )
        isRecordingShortcut = false
        updateTitle(for: configuration)
        window?.makeFirstResponder(nil)
        onCapture?(configuration)
    }

    private static func displayString(for shortcut: HotKeyConfiguration) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlagsRawValue)
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        return value + shortcut.displayKey
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            let characters = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            return characters.isEmpty ? "Key \(event.keyCode)" : characters
        }
    }
}
