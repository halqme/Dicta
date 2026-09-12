import ApplicationServices
import Foundation

actor TargetResolver {
    enum TargetResolutionDecision: Equatable, Sendable {
        case accessibility
        case pasteboardFallback
        case fallbackEditor
    }

    struct TextSelection: Equatable, Sendable {
        let location: Int
        let length: Int

        func isValid(characterCount: Int) -> Bool {
            guard characterCount >= 0,
                  location >= 0,
                  length >= 0,
                  location <= characterCount
            else { return false }
            return length <= characterCount - location
        }
    }

    /// Pure target policy retained as a testable boundary; live AX capture remains in the
    /// delivery actor so no AXUIElement crosses into DictationSession.
    struct TextTargetProbe: Equatable, Sendable {
        let role: String?
        let subrole: String?
        let isEditable: Bool?
        let valueIsSettable: Bool?
        let selectionIsSettable: Bool?
        let selectedRange: TextSelection?
        let characterCount: Int?

        init(
            role: String? = nil,
            subrole: String? = nil,
            isEditable: Bool? = nil,
            valueIsSettable: Bool? = nil,
            selectionIsSettable: Bool? = nil,
            selectedRange: TextSelection? = nil,
            characterCount: Int? = nil
        ) {
            self.role = role
            self.subrole = subrole
            self.isEditable = isEditable
            self.valueIsSettable = valueIsSettable
            self.selectionIsSettable = selectionIsSettable
            self.selectedRange = selectedRange
            self.characterCount = characterCount
        }
    }

    nonisolated static func decision(for probe: TextTargetProbe) -> TargetResolutionDecision {
        if probe.subrole == (kAXSecureTextFieldSubrole as String) {
            return .fallbackEditor
        }

        let isTextRole = probe.role == (kAXTextFieldRole as String)
            || probe.role == (kAXTextAreaRole as String)
        guard isTextRole else { return .pasteboardFallback }
        guard probe.subrole != nil,
              probe.isEditable == true,
              probe.valueIsSettable == true,
              probe.selectionIsSettable == true,
              let selectedRange = probe.selectedRange,
              let characterCount = probe.characterCount,
              selectedRange.isValid(characterCount: characterCount)
        else { return .pasteboardFallback }
        return .accessibility
    }

    /// The same service must later receive the resolved target so its actor-owned capture handle
    /// remains valid. Expose the injected reference to make the default wiring usable as well.
    nonisolated let deliveryService: InputDeliveryService

    init(inputDeliveryService: InputDeliveryService = InputDeliveryService()) {
        self.deliveryService = inputDeliveryService
    }

    /// Resolve once at recording start. Finalization must not re-target whatever happens
    /// to be focused when ASR later completes. InputDeliveryService owns the live AX capture.
    func resolveCurrentTarget() async -> DictationTarget {
        await deliveryService.captureCurrentTarget()
    }
}
