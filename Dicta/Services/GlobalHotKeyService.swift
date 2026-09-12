import AppKit
import Carbon
import Foundation

@MainActor
final class GlobalHotKeyService {
    enum HotKeyError: LocalizedError {
        case handlerRegistrationFailed(OSStatus)
        case shortcutRegistrationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .handlerRegistrationFailed(let status):
                "Dicta could not install its global shortcut handler (OSStatus \(status))."
            case .shortcutRegistrationFailed(let status):
                "That global shortcut could not be registered (OSStatus \(status)). Try another shortcut."
            }
        }
    }

    private enum ID {
        static let dictation: UInt32 = 1
        static let cancel: UInt32 = 2
    }

    private static let signature: OSType = 0x44696374 // "Dict"

    private var eventHandler: EventHandlerRef?
    private var dictationHotKey: EventHotKeyRef?
    private var currentConfiguration: HotKeyConfiguration?
    private var cancelHotKey: EventHotKeyRef?

    var onPressed: (@MainActor @Sendable () -> Void)?
    var onReleased: (@MainActor @Sendable () -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?

    var registeredConfiguration: HotKeyConfiguration? { currentConfiguration }

    init() throws {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let status = eventTypes.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                DictaHotKeyEventHandler,
                buffer.count,
                buffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
        }
        guard status == noErr else {
            throw HotKeyError.handlerRegistrationFailed(status)
        }
    }

    func register(_ configuration: HotKeyConfiguration) throws {
        guard currentConfiguration != configuration || dictationHotKey == nil else { return }

        // Register the replacement before removing the working shortcut. A conflicting new
        // shortcut therefore cannot strand the user without the previous activation path.
        let id = EventHotKeyID(signature: Self.signature, id: ID.dictation)
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(
            configuration.keyCode,
            Self.carbonModifiers(from: configuration.modifierFlagsRawValue),
            id,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &replacement
        )
        guard status == noErr, let replacement else {
            throw HotKeyError.shortcutRegistrationFailed(status)
        }

        if let dictationHotKey {
            UnregisterEventHotKey(dictationHotKey)
        }
        dictationHotKey = replacement
        currentConfiguration = configuration
    }

    func setCancelShortcutEnabled(_ enabled: Bool) {
        if !enabled {
            if let cancelHotKey {
                UnregisterEventHotKey(cancelHotKey)
                self.cancelHotKey = nil
            }
            return
        }
        guard cancelHotKey == nil else { return }

        let id = EventHotKeyID(signature: Self.signature, id: ID.cancel)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            id,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &reference
        )
        if status == noErr {
            cancelHotKey = reference
        }
    }

    fileprivate func handle(id: UInt32, kind: UInt32) {
        switch (id, kind) {
        case (ID.dictation, UInt32(kEventHotKeyPressed)):
            onPressed?()
        case (ID.dictation, UInt32(kEventHotKeyReleased)):
            onReleased?()
        case (ID.cancel, UInt32(kEventHotKeyPressed)):
            onCancel?()
        default:
            break
        }
    }

    private static func carbonModifiers(from rawValue: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: rawValue)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

nonisolated private func DictaHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    guard GetEventClass(event) == OSType(kEventClassKeyboard) else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == 0x44696374 else {
        return OSStatus(eventNotHandledErr)
    }

    let id = hotKeyID.id
    let kind = GetEventKind(event)
    let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        service.handle(id: id, kind: kind)
    }
    return noErr
}
