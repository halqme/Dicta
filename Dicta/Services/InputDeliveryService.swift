import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Pure UTF-16 range replacement used by the AX delivery path.
nonisolated enum AccessibilityTextEdit {
    static func replacingCharacters(
        in text: String,
        range: NSRange,
        with replacement: String
    ) -> String? {
        let source = text as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.location <= source.length,
              range.length <= source.length - range.location
        else { return nil }
        return source.replacingCharacters(in: range, with: replacement)
    }
}

actor InputDeliveryService {
    enum DeliveryError: Error, LocalizedError, Equatable, Sendable {
        case unsupportedTarget
        case targetNoLongerSafeForPaste
        case pasteFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedTarget:
                "The captured text target is no longer writable."
            case .targetNoLongerSafeForPaste:
                "The original paste destination is no longer the frontmost application."
            case .pasteFailed:
                "The transcript could not be delivered while preserving the clipboard."
            }
        }
    }

    /// A live AXUIElement is intentionally kept only in this actor. DictationTarget contains the
    /// UUID handle and the application PID, both of which are Sendable.
    private final class AccessibilityTargetCapture {
        let element: AXUIElement
        let applicationPID: Int32
        let role: String
        let subrole: String
        let identifier: String?
        let capturedValue: String
        let selectedRange: NSRange

        init(
            element: AXUIElement,
            applicationPID: Int32,
            role: String,
            subrole: String,
            identifier: String?,
            capturedValue: String,
            selectedRange: NSRange
        ) {
            self.element = element
            self.applicationPID = applicationPID
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
            self.capturedValue = capturedValue
            self.selectedRange = selectedRange
        }
    }

    private final class PasteboardTargetCapture {
        let element: AXUIElement
        let applicationPID: Int32
        let role: String
        let subrole: String
        let identifier: String?

        init(
            element: AXUIElement,
            applicationPID: Int32,
            role: String,
            subrole: String,
            identifier: String?
        ) {
            self.element = element
            self.applicationPID = applicationPID
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
        }
    }

    private enum FocusedTarget {
        case accessibility(AccessibilityTargetCapture)
        case pasteboard(PasteboardTargetCapture)
        case protectedText
        case fallbackEditor
    }

    private var accessibilityCaptures: [UUID: AccessibilityTargetCapture] = [:]
    private var pasteboardCaptures: [UUID: PasteboardTargetCapture] = [:]
    private var pendingPasteboardCaptures: Set<UUID> = []
    private var overlappingPasteboardCaptures: Set<UUID> = []

    /// Capture the focused destination once, before recording starts. No later call reads the
    /// focused element for AX insertion.
    func captureCurrentTarget() -> DictationTarget {
        switch captureFocusedTarget() {
        case .accessibility(let capture):
            let captureID = UUID()
            accessibilityCaptures[captureID] = capture
            return .accessibilityCapture(
                applicationPID: capture.applicationPID,
                captureID: captureID
            )

        case .protectedText, .fallbackEditor:
            // Secure text and an unresolvable target must never be bypassed with simulated paste.
            return .fallbackEditor

        case .pasteboard(let capture):
            let captureID = UUID()
            pasteboardCaptures[captureID] = capture
            if !pendingPasteboardCaptures.isEmpty {
                overlappingPasteboardCaptures.formUnion(pendingPasteboardCaptures)
                overlappingPasteboardCaptures.insert(captureID)
            }
            pendingPasteboardCaptures.insert(captureID)
            return .pasteboardCapture(
                applicationPID: capture.applicationPID,
                captureID: captureID
            )
        }
    }

    /// Remove a capture when a recording is cancelled before finalization.
    func discard(_ target: DictationTarget) {
        switch target {
        case .accessibilityCapture(_, let captureID):
            accessibilityCaptures.removeValue(forKey: captureID)
        case .pasteboardCapture(_, let captureID):
            pasteboardCaptures.removeValue(forKey: captureID)
            pendingPasteboardCaptures.remove(captureID)
            overlappingPasteboardCaptures.remove(captureID)
        case .accessibility, .pasteboardFallback, .fallbackEditor:
            break
        }
    }

    /// Delivery policy:
    /// 1. AX direct insertion using the captured element and selection.
    /// 2. Best-effort pasteboard paste for a single non-AX capture whose application is still frontmost.
    /// 3. Fallback editor for unsafe or overlapping non-AX sessions.
    func deliver(
        _ result: TranscriptResult,
        to target: DictationTarget
    ) async throws -> TranscriptHistoryItem.Destination {
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            discard(target)
            throw DeliveryError.pasteFailed
        }

        switch target {
        case .accessibility:
            // A PID alone is not a stable text destination; the original element must have been
            // captured before finalization.
            throw DeliveryError.unsupportedTarget

        case let .accessibilityCapture(applicationPID, captureID):
            guard let capture = accessibilityCaptures[captureID],
                  capture.applicationPID == applicationPID,
                  processIdentifier(of: capture.element) == applicationPID
            else { throw DeliveryError.unsupportedTarget }
            defer { accessibilityCaptures.removeValue(forKey: captureID) }
            do {
                try insertAccessibility(result.text, into: capture)
                return .accessibility
            } catch {
                // Direct AX insertion is deliberately strict (the captured value/range must still
                // match). If it becomes stale but the exact same element is still focused, the
                // standard Cmd-V path is a safe secondary delivery mechanism.
                let pasteCapture = PasteboardTargetCapture(
                    element: capture.element,
                    applicationPID: capture.applicationPID,
                    role: capture.role,
                    subrole: capture.subrole,
                    identifier: capture.identifier
                )
                return try await deliverUsingPasteboard(result, focusedCapture: pasteCapture)
            }

        case let .pasteboardCapture(applicationPID, captureID):
            defer {
                pasteboardCaptures.removeValue(forKey: captureID)
                pendingPasteboardCaptures.remove(captureID)
                overlappingPasteboardCaptures.remove(captureID)
            }
            guard let capture = pasteboardCaptures[captureID],
                  capture.applicationPID == applicationPID,
                  !overlappingPasteboardCaptures.contains(captureID),
                  pendingPasteboardCaptures.count == 1
            else { return .fallbackEditor }
            return try await deliverUsingPasteboard(result, focusedCapture: capture)

        case .pasteboardFallback:
            // A PID-only target cannot prove which window/control still owns focus. New captures
            // use pasteboardCapture with an AX focus identity; keep this legacy case safe.
            return .fallbackEditor

        case .fallbackEditor:
            return .fallbackEditor
        }
    }

    private func captureFocusedTarget() -> FocusedTarget {
        guard AXIsProcessTrusted() else {
            return .fallbackEditor
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        guard let applicationValue = copyAttribute(
            kAXFocusedApplicationAttribute as CFString,
            from: systemWideElement
        ),
        let application = axUIElement(from: applicationValue),
        let applicationPID = processIdentifier(of: application),
        let focusedValue = copyAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: application
        ),
        let focusedElement = axUIElement(from: focusedValue),
        processIdentifier(of: focusedElement) == applicationPID
        else {
            return .fallbackEditor
        }

        guard let role = stringAttribute(kAXRoleAttribute as CFString, from: focusedElement) else {
            return .fallbackEditor
        }
        if role == "AXSecureTextField" {
            return .protectedText
        }
        let isTextRole = role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
        guard isTextRole else {
            return .pasteboard(
                PasteboardTargetCapture(
                    element: focusedElement,
                    applicationPID: applicationPID,
                    role: role,
                    subrole: stringAttribute(kAXSubroleAttribute as CFString, from: focusedElement) ?? role,
                    identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: focusedElement)
                )
            )
        }
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: focusedElement) ?? role
        if subrole == (kAXSecureTextFieldSubrole as String) {
            return .protectedText
        }

        guard isWritableTextTarget(focusedElement),
              let value = stringAttribute(kAXValueAttribute as CFString, from: focusedElement),
              let selectedRange = selectedTextRange(from: focusedElement),
              selectedRange.location <= (value as NSString).length,
              selectedRange.length <= (value as NSString).length - selectedRange.location
        else {
            // A non-secure text control that does not expose a writable AX value is still a
            // normal candidate for Cmd-V. Capture its exact focused element so delayed delivery
            // can verify that focus has not moved.
            return .pasteboard(
                PasteboardTargetCapture(
                    element: focusedElement,
                    applicationPID: applicationPID,
                    role: role,
                    subrole: subrole,
                    identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: focusedElement)
                )
            )
        }

        return .accessibility(
            AccessibilityTargetCapture(
                element: focusedElement,
                applicationPID: applicationPID,
                role: role,
                subrole: subrole,
                identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: focusedElement),
                capturedValue: value,
                selectedRange: selectedRange
            )
        )
    }

    private func insertAccessibility(
        _ text: String,
        into capture: AccessibilityTargetCapture
    ) throws {
        let currentRole = stringAttribute(kAXRoleAttribute as CFString, from: capture.element)
        let currentSubrole = currentRole.map {
            stringAttribute(kAXSubroleAttribute as CFString, from: capture.element) ?? $0
        }
        guard processIdentifier(of: capture.element) == capture.applicationPID,
              currentRole == capture.role,
              currentSubrole == capture.subrole,
              stringAttribute(kAXIdentifierAttribute as CFString, from: capture.element) == capture.identifier,
              isWritableTextTarget(capture.element),
              let currentValue = stringAttribute(kAXValueAttribute as CFString, from: capture.element),
              currentValue == capture.capturedValue,
              let updatedValue = AccessibilityTextEdit.replacingCharacters(
                  in: currentValue,
                  range: capture.selectedRange,
                  with: text
              )
        else { throw DeliveryError.unsupportedTarget }

        guard AXUIElementSetAttributeValue(
            capture.element,
            kAXValueAttribute as CFString,
            updatedValue as CFString
        ) == .success
        else { throw DeliveryError.unsupportedTarget }

        // AX success alone is insufficient: apps can disappear or normalize a failed write.
        guard stringAttribute(kAXValueAttribute as CFString, from: capture.element) == updatedValue else {
            throw DeliveryError.unsupportedTarget
        }

        // Best effort only. The text has already been confirmed; failure to move the caret must
        // not cause a second delivery through another path.
        let newCaret = NSRange(
            location: capture.selectedRange.location + (text as NSString).length,
            length: 0
        )
        if let value = axValue(for: newCaret) {
            _ = AXUIElementSetAttributeValue(
                capture.element,
                kAXSelectedTextRangeAttribute as CFString,
                value
            )
        }
    }

    private func isWritableTextTarget(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute as CFString, from: element),
              role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String),
              isAttributeSettable(kAXValueAttribute as CFString, on: element),
              isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
        else { return false }

        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element) ?? role
        guard subrole != (kAXSecureTextFieldSubrole as String) else { return false }
        if let editable = copyAttribute(kAXIsEditableAttribute as CFString, from: element) {
            guard booleanValue(editable) == true else { return false }
        }
        return true
    }

    private func deliverUsingPasteboard(
        _ result: TranscriptResult,
        focusedCapture: PasteboardTargetCapture
    ) async throws -> TranscriptHistoryItem.Destination {
        let applicationPID = focusedCapture.applicationPID
        guard isCurrentPasteTarget(applicationPID),
              isCurrentFocusedTarget(focusedCapture)
        else { throw DeliveryError.targetNoLongerSafeForPaste }
        guard CGPreflightPostEventAccess() else { throw DeliveryError.pasteFailed }

        let pasteboard = NSPasteboard.general
        let snapshot = try PasteboardSnapshot(capturing: pasteboard)
        guard pasteboard.changeCount == snapshot.changeCount,
              isCurrentPasteTarget(applicationPID),
              isCurrentFocusedTarget(focusedCapture)
        else { throw DeliveryError.targetNoLongerSafeForPaste }

        var temporaryPasteboardChangeCount: Int?
        do {
            let countBeforeClear = pasteboard.changeCount
            guard countBeforeClear == snapshot.changeCount else {
                throw DeliveryError.targetNoLongerSafeForPaste
            }
            temporaryPasteboardChangeCount = countBeforeClear
            let clearedCount = pasteboard.clearContents()
            guard clearedCount == countBeforeClear + 1,
                  pasteboard.changeCount == clearedCount
            else { throw DeliveryError.pasteFailed }
            temporaryPasteboardChangeCount = clearedCount

            guard pasteboard.changeCount == clearedCount,
                  pasteboard.setString(result.text, forType: .string)
            else { throw DeliveryError.pasteFailed }

            let countAfterWrite = pasteboard.changeCount
            // setString mutates the contents owned by the declaration; it does not advance the
            // declaration's change count. Any increment here therefore belongs to another writer.
            guard countAfterWrite == clearedCount else { throw DeliveryError.pasteFailed }
            temporaryPasteboardChangeCount = countAfterWrite

            guard isCurrentPasteTarget(applicationPID),
                  isCurrentFocusedTarget(focusedCapture),
                  pasteboard.changeCount == countAfterWrite
            else { throw DeliveryError.targetNoLongerSafeForPaste }

            try postPasteShortcut()
            // The target app needs a turn to consume the temporary transcript before restoration.
            try await Task.sleep(nanoseconds: 100_000_000)

            if let temporaryPasteboardChangeCount {
                try restore(snapshot, to: pasteboard, ifChangeCountIs: temporaryPasteboardChangeCount)
            }
            return .pasteboard
        } catch {
            if let temporaryPasteboardChangeCount {
                do {
                    try restore(snapshot, to: pasteboard, ifChangeCountIs: temporaryPasteboardChangeCount)
                } catch {
                    throw DeliveryError.pasteFailed
                }
            }
            throw error
        }
    }

    private func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        ifChangeCountIs expectedChangeCount: Int
    ) throws {
        // A changed count belongs to a newer clipboard writer; never overwrite it.
        guard pasteboard.changeCount == expectedChangeCount else { return }
        let clearedCount = pasteboard.clearContents()
        guard clearedCount == expectedChangeCount + 1 else {
            // A larger count means another writer won the race; do not overwrite it.
            if pasteboard.changeCount > expectedChangeCount { return }
            throw DeliveryError.pasteFailed
        }
        guard pasteboard.changeCount == clearedCount else { return }
        guard snapshot.restoreContents(to: pasteboard) else { throw DeliveryError.pasteFailed }
        // writeObjects should retain the declaration count. If it changed, another writer raced
        // the restoration; never attempt to restore the old snapshot again.
        guard pasteboard.changeCount == clearedCount else { return }
    }

    private func isCurrentPasteTarget(_ applicationPID: Int32) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated
        else { return false }
        return frontmost.processIdentifier == applicationPID
    }

    private func isCurrentFocusedTarget(_ capture: PasteboardTargetCapture) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let applicationValue = copyAttribute(
            kAXFocusedApplicationAttribute as CFString,
            from: systemWideElement
        ),
        let application = axUIElement(from: applicationValue),
        processIdentifier(of: application) == capture.applicationPID,
        let focusedValue = copyAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: application
        ),
        let focusedElement = axUIElement(from: focusedValue),
        processIdentifier(of: focusedElement) == capture.applicationPID,
        let role = stringAttribute(kAXRoleAttribute as CFString, from: focusedElement),
        role == capture.role
        else { return false }

        let currentSubrole = stringAttribute(kAXSubroleAttribute as CFString, from: focusedElement) ?? role
        guard currentSubrole == capture.subrole else { return false }
        if let identifier = capture.identifier {
            return stringAttribute(kAXIdentifierAttribute as CFString, from: focusedElement) == identifier
        }
        return CFEqual(capture.element, focusedElement)
    }

    private func postPasteShortcut() throws {
        guard let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 9,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 9,
            keyDown: false
        )
        else { throw DeliveryError.pasteFailed }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private func axUIElement(from value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func processIdentifier(of element: AXUIElement) -> Int32? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return Int32(pid)
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return value as? String
    }

    private func booleanValue(_ value: CFTypeRef) -> Bool? {
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    private func selectedTextRange(from element: AXUIElement) -> NSRange? {
        guard let value = copyAttribute(kAXSelectedTextRangeAttribute as CFString, from: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func axValue(for range: NSRange) -> AXValue? {
        var cfRange = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &cfRange)
    }

    private struct PasteboardSnapshot {
        private struct Representation {
            let type: NSPasteboard.PasteboardType
            let data: Data
        }

        private struct Item {
            let representations: [Representation]
        }

        let changeCount: Int
        private let items: [Item]

        init(capturing pasteboard: NSPasteboard) throws {
            let initialChangeCount = pasteboard.changeCount
            let pasteboardItems = pasteboard.pasteboardItems ?? []
            var capturedItems: [Item] = []
            capturedItems.reserveCapacity(pasteboardItems.count)

            for item in pasteboardItems {
                var representations: [Representation] = []
                representations.reserveCapacity(item.types.count)
                for type in item.types {
                    guard let data = item.data(forType: type) else { throw DeliveryError.pasteFailed }
                    representations.append(Representation(type: type, data: data))
                }
                guard !representations.isEmpty else { throw DeliveryError.pasteFailed }
                capturedItems.append(Item(representations: representations))
            }

            guard pasteboard.changeCount == initialChangeCount else {
                throw DeliveryError.targetNoLongerSafeForPaste
            }
            changeCount = initialChangeCount
            items = capturedItems
        }

        func restoreContents(to pasteboard: NSPasteboard) -> Bool {
            guard !items.isEmpty else { return true }
            var restoredItems: [NSPasteboardItem] = []
            restoredItems.reserveCapacity(items.count)
            for item in items {
                let pasteboardItem = NSPasteboardItem()
                for representation in item.representations {
                    guard pasteboardItem.setData(
                        representation.data,
                        forType: representation.type
                    ) else { return false }
                }
                restoredItems.append(pasteboardItem)
            }
            return pasteboard.writeObjects(restoredItems)
        }
    }
}
