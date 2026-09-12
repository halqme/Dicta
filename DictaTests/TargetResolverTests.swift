import Testing
@testable import Dicta

@Test
func writableTextTargetIsEligibleForAccessibilityDelivery() {
    let probe = TargetResolver.TextTargetProbe(
        role: "AXTextField",
        subrole: "AXTextField",
        isEditable: true,
        valueIsSettable: true,
        selectionIsSettable: true,
        selectedRange: .init(location: 4, length: 0),
        characterCount: 12
    )

    #expect(TargetResolver.decision(for: probe) == .accessibility)
}

@Test
func secureTextTargetAlwaysUsesFallbackEditor() {
    let probe = TargetResolver.TextTargetProbe(
        role: "AXTextField",
        subrole: "AXSecureTextField",
        isEditable: true,
        valueIsSettable: true,
        selectionIsSettable: true,
        selectedRange: .init(location: 0, length: 3),
        characterCount: 3
    )

    #expect(TargetResolver.decision(for: probe) == .fallbackEditor)
}

@Test
func nonWritableNonSecureTextTargetUsesPasteFallback() {
    let probe = TargetResolver.TextTargetProbe(
        role: "AXTextArea",
        subrole: "AXTextArea",
        isEditable: false,
        valueIsSettable: false,
        selectionIsSettable: true,
        selectedRange: .init(location: 2, length: 0),
        characterCount: 5
    )

    #expect(TargetResolver.decision(for: probe) == .pasteboardFallback)
}

@Test
func invalidSelectionUsesPasteFallbackInsteadOfDirectCapture() {
    let probe = TargetResolver.TextTargetProbe(
        role: "AXTextField",
        subrole: "AXTextField",
        isEditable: true,
        valueIsSettable: true,
        selectionIsSettable: true,
        selectedRange: .init(location: 8, length: 1),
        characterCount: 8
    )

    #expect(TargetResolver.decision(for: probe) == .pasteboardFallback)
}

@Test
func nonTextFocusedElementUsesPasteboardFallback() {
    let probe = TargetResolver.TextTargetProbe(role: "AXButton", subrole: "AXButton")

    #expect(TargetResolver.decision(for: probe) == .pasteboardFallback)
}
