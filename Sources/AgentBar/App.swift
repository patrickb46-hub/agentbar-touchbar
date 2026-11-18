import AppKit
import Foundation

enum AgentBarApp {
    static func run() {
        Paths.ensure()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let host = TouchBarHost()
    private var statusItem: NSStatusItem?
    private var statusLabel = NSMenuItem(title: "启动中…", action: nil, keyEquivalent: "")
    private var attachLabel = NSMenuItem(title: "Touch Bar", action: nil, keyEquivalent: "")
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        host.start()
        installSignalHandlers()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
        if ProcessInfo.processInfo.environment["AGENTBAR_CALIBRATE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.host.view.beginCalibration()
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "bolt.horizontal.fill", accessibilityDescription: "AgentBar")
            button.image?.isTemplate = true
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        let menu = NSMenu()
        statusLabel.isEnabled = false
        attachLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(attachLabel)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "重新挂载 Touch Bar", action: #selector(reattach), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "校准右侧边界（点一下最右可用位置）", action: #selector(calibrate), keyEquivalent: "k"))
        menu.addItem(NSMenuItem(title: "导出预览图…", action: #selector(exportPreview), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "打开状态目录", action: #selector(openStateDir), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 AgentBar", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items where entry.action != nil { entry.target = self }
        item.menu = menu
        statusItem = item
    }

    private func tick() {
        Store.shared.refreshTodayIfNeeded()
        let model = Store.shared.model()

        host.view.model = model
        host.view.needsDisplay = true

        let attached = host.isAttached
        attachLabel.title = attached ? "Touch Bar：已接管" : "Touch Bar：未接管（仅菜单栏）"

        if let primary = model.primary, primary.isLive || primary.phase == .done {
            let elapsed = primary.elapsed.map { " " + clockText($0) } ?? ""
            statusLabel.title = "\(primary.phase.label)\(elapsed) · \(primary.project)"
            statusItem?.button?.title = " \(primary.phase.label)\(elapsed)"
        } else if model.today.isEmpty {
            statusLabel.title = "暂无 AI 活动"
            statusItem?.button?.title = ""
        } else {
            statusLabel.title = "今日 \(model.today.turns) 轮 · \(model.today.durationText)"
            statusItem?.button?.title = " \(model.today.durationText)"
        }
    }

    @objc private func reattach() {
        host.dismiss()
        _ = host.present()
    }

    @objc private func calibrate() {
        host.view.beginCalibration()
    }

    @objc private func exportPreview() {
        let path = NSHomeDirectory() + "/Desktop/agentbar-preview.png"
        CLI.writePNG(model: Store.shared.model(), to: path)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openStateDir() {
        Paths.ensure()
        NSWorkspace.shared.open(Paths.stateDir)
    }

    @objc private func quit() {
        gracefulExit()
    }

    /// 正常退出或被 kill 时都要把 Touch Bar 还回去，
    /// 否则系统会把最后一帧冻在屏幕上（看起来像卡住了）。
    func gracefulExit() {
        host.dismiss()
        Log.write("退出：已收起 Touch Bar")
        statusItem?.isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
            exit(0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        host.dismiss()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { _ in
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.gracefulExit()
                }
            }
        }
    }
}
