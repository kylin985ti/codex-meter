import AppKit
import SwiftUI

@main
enum CodexMeterMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var desktopPanel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["showDesktopPanel": true])
        configureStatusItem()
        configurePopover()
        configureDesktopPanel()

        store.onSnapshotChange = { [weak self] snapshot in
            self?.updateStatusItem(snapshot)
        }
        store.start()

        if UserDefaults.standard.bool(forKey: "showDesktopPanel") {
            showDesktopPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "Codex Meter")
            button.imagePosition = .imageLeading
            button.title = " --"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Codex Meter"
        }
        statusItem = item
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 368, height: 490)
        popover.contentViewController = NSHostingController(
            rootView: MeterView(store: store, presentation: .popover, actions: actions)
        )
    }

    private func configureDesktopPanel() {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 510),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(
            rootView: MeterView(store: store, presentation: .desktop, actions: actions)
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        if !panel.setFrameUsingName("CodexMeterDesktopPanel") || !isFrameVisible(panel.frame) {
            positionAtTopRight(panel)
        }
        panel.setFrameAutosaveName("CodexMeterDesktopPanel")
        desktopPanel = panel
    }

    private var actions: MeterActions {
        MeterActions(
            toggleDesktop: { [weak self] in self?.toggleDesktopPanel() },
            openUsagePage: { [weak self] in self?.openUsagePage() },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func toggleDesktopPanel() {
        guard let panel = desktopPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            UserDefaults.standard.set(false, forKey: "showDesktopPanel")
        } else {
            showDesktopPanel()
        }
    }

    private func showDesktopPanel() {
        guard let panel = desktopPanel else { return }
        if !isFrameVisible(panel.frame) {
            positionAtTopRight(panel)
        }
        panel.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "showDesktopPanel")
    }

    private func updateStatusItem(_ snapshot: UsageSnapshot) {
        let remaining = MeterFormat.percent(snapshot.headlineRemainingPercent)
        statusItem?.button?.title = " " + remaining
        statusItem?.button?.toolTip = "Codex 额度剩余 \(remaining) · 今日 \(MeterFormat.compactTokens(snapshot.todayTokens)) tokens"
    }

    private func openUsagePage() {
        guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
        NSWorkspace.shared.open(url)
    }

    private func positionAtTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - panel.frame.width - 22,
            y: visible.maxY - panel.frame.height - 22
        )
        panel.setFrameOrigin(origin)
    }

    private func isFrameVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
