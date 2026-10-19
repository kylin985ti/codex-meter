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
    private var popoverHosting: NSHostingController<MeterView>?
    private var panelHosting: NSHostingController<MeterView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["showDesktopPanel": true])
        configureStatusItem()
        configurePopover()
        configureDesktopPanel()

        store.onSnapshotChange = { [weak self] snapshot in
            self?.updateStatusItem(snapshot)
            self?.resizeToContent()
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
            setStatusTitle(" C --")
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Codex Meter"
        }
        statusItem = item
    }

    // 等宽数字：百分比变化时状态栏宽度不跳动。
    private func setStatusTitle(_ text: String) {
        guard let button = statusItem?.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 392, height: 760)
        let hosting = NSHostingController(
            rootView: MeterView(store: store, presentation: .popover, actions: actions)
        )
        popover.contentViewController = hosting
        popoverHosting = hosting
    }

    // 卡片内容随数据增减变化（Ollama 区块可能显示两张额度卡，也可能只显示一行提示），
    // 因此按实际内容高度自适应，并把高度上限压在屏幕可视区内，避免超出后被裁掉。
    private func resizeToContent() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let maxHeight = max(320, screen.visibleFrame.height - 40)

        if let hosting = popoverHosting {
            hosting.view.layoutSubtreeIfNeeded()
            let height = min(hosting.view.fittingSize.height, maxHeight)
            if height > 0, abs(popover.contentSize.height - height) > 6 {
                popover.contentSize = NSSize(width: 392, height: height)
            }
        }

        guard let panel = desktopPanel, let hosting = panelHosting else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let height = min(hosting.view.fittingSize.height, maxHeight)
        guard height > 0 else { return }

        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
        clampToScreen(panel)
    }

    // 兜底：无论自适应高度还是历史保存的位置，都不允许卡片超出可视区。
    private func clampToScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame

        // 窗口刚挂上 SwiftUI 内容时可能报告 0 尺寸，此时任何钳制都没有意义，
        // 交给 resizeToContent 用真实内容尺寸再处理。
        guard frame.width > 1, frame.height > 1 else { return }

        frame.size.height = min(frame.height, visible.height - 20)
        frame.size.width = min(frame.width, visible.width - 20)
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }

        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func configureDesktopPanel() {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 384, height: 760),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingController(
            rootView: MeterView(store: store, presentation: .desktop, actions: actions)
        )
        panel.contentViewController = hosting
        panelHosting = hosting
        // 挂上 SwiftUI 内容后 AppKit 会把窗口尺寸交给内容视图，这里先固定回卡片宽度，
        // 否则紧接着的定位逻辑可能读到 0 尺寸而把窗口放到屏幕外。
        panel.setContentSize(NSSize(width: 384, height: 760))
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
        // AppKit 可能在窗口首次上屏时才应用自动保存的位置，因此上屏后再钳制一次。
        clampToScreen(panel)
        UserDefaults.standard.set(true, forKey: "showDesktopPanel")
    }

    private func updateStatusItem(_ snapshot: UsageSnapshot) {
        let codexWindow = snapshot.rateLimits?.primary ?? snapshot.rateLimits?.secondary
        let codexRemaining = MeterFormat.percent(codexWindow?.remainingPercent)

        // 状态栏空间有限：C = Codex，O = Ollama Cloud，各取当前最紧的窗口（5 小时）。
        var segments = ["C " + codexRemaining]
        if let ollama = snapshot.ollama {
            if ollama.hasWindows {
                let shortWindow = ollama.session ?? ollama.weekly
                segments.append("O " + MeterFormat.percent(shortWindow?.remainingPercent))
            } else {
                segments.append("O --")
            }
        }
        setStatusTitle(" " + segments.joined(separator: " · "))

        var tooltip = "Codex 剩余 \(codexRemaining)"
        if let reset = codexWindow?.resetsAt {
            tooltip += "（\(MeterFormat.resetText(reset))）"
        }
        tooltip += "\n今日 \(MeterFormat.compactTokens(snapshot.todayTokens)) tokens"

        if let ollama = snapshot.ollama, ollama.hasWindows {
            var line = "Ollama 剩余：5 小时 \(MeterFormat.percent(ollama.session?.remainingPercent))"
            if let reset = ollama.session?.resetsAt {
                line += "（\(MeterFormat.resetText(reset))）"
            }
            line += " · 7 天 \(MeterFormat.percent(ollama.weekly?.remainingPercent))"
            tooltip += "\n" + line
            if let requests = ollama.requests24h {
                tooltip += "\n24 小时请求 \(requests) 次"
            }
        } else if let note = snapshot.ollama?.note {
            tooltip += "\nOllama：\(note)"
        }
        statusItem?.button?.toolTip = tooltip
    }

    private func openUsagePage() {
        guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
        NSWorkspace.shared.open(url)
    }

    private func positionAtTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        // 窗口尺寸可能尚未由内容视图确定，退回卡片的最小可用尺寸，避免按 0 计算。
        let width = max(panel.frame.width, 384)
        let height = max(panel.frame.height, 320)
        let origin = NSPoint(
            x: visible.maxX - width - 22,
            y: visible.maxY - height - 22
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    }

    private func isFrameVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
