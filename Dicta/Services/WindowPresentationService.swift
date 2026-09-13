import AppKit
import SwiftUI

@MainActor
final class WindowPresentationService: NSObject, NSWindowDelegate {
    private var livePanel: NSPanel?
    private var fallbackWindow: NSWindow?
    private var menuTrackingDepth = 0
    private var pendingPresentation: (() -> Void)?
    private var presentationInFlight = false

    override init() {
        super.init()
        // MenuBarExtra invokes actions while its NSMenu is tracking. Wait for didEndTracking
        // before touching the user-facing window so activation is not swallowed by the menu.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func showSettings(openSettings: @escaping () -> Void) {
        requestWindowPresentation { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            self?.settingsDidAppearIfAlreadyVisible()
        }
    }

    func showLiveHUD(appModel: AppModel) {
        let panel: NSPanel
        if let livePanel {
            panel = livePanel
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 72),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isFloatingPanel = true
            created.becomesKeyOnlyIfNeeded = true
            created.level = .floating
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            created.hidesOnDeactivate = false
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.contentView = NSHostingView(rootView: LiveTranscriptView(appModel: appModel))
            livePanel = created
            panel = created
        }

        positionLiveHUD(panel)
        panel.orderFrontRegardless()
    }

    func hideLiveHUD() {
        livePanel?.orderOut(nil)
    }

    func showFallbackEditor(appModel: AppModel) {
        let window: NSWindow
        if let fallbackWindow {
            window = fallbackWindow
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = "Dicta — Fallback Editor"
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.contentMinSize = NSSize(width: 420, height: 240)
            created.contentView = NSHostingView(rootView: FallbackEditorView(appModel: appModel))
            created.center()
            fallbackWindow = created
            window = created
        }

        requestWindowPresentation { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            self?.presentationInFlight = false
        }
    }

    func settingsDidAppear() {
        presentationInFlight = false
    }

    func restoreAccessoryPolicyIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.menuTrackingDepth == 0,
                  self.pendingPresentation == nil,
                  !self.presentationInFlight,
                  !self.hasVisibleApplicationWindow else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === fallbackWindow else { return }
        restoreAccessoryPolicyIfNeeded()
    }

    private func requestWindowPresentation(_ action: @escaping () -> Void) {
        // Keep regular policy until the target window or its SwiftUI content is visible. This
        // also prevents a close callback from undoing a presentation already in progress.
        presentationInFlight = true
        NSApp.setActivationPolicy(.regular)

        if menuTrackingDepth == 0 {
            action()
        } else {
            pendingPresentation = action
        }
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        menuTrackingDepth += 1
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        menuTrackingDepth = max(menuTrackingDepth - 1, 0)
        guard menuTrackingDepth == 0, let action = pendingPresentation else { return }

        pendingPresentation = nil
        DispatchQueue.main.async {
            action()
        }
    }

    private func settingsDidAppearIfAlreadyVisible() {
        guard NSApp.windows.contains(where: { window in
            window.isVisible
                && window.styleMask.contains(.titled)
                && window !== fallbackWindow
        }) else { return }
        presentationInFlight = false
    }

    private var hasVisibleApplicationWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    private func positionLiveHUD(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 72
        )
        panel.setFrameOrigin(origin)
    }
}
