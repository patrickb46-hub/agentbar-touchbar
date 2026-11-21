import AppKit
import Foundation
import SwiftUI

enum AgentBarApp {
    static func run() {
        Paths.ensure()
        waitForPreviousInstance()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

extension AgentBarApp {
    /// 同一个 App 被拷了几份时，macOS 允许同时跑多个进程，它们会抢同一个 Touch Bar，
    /// 所以后启动的那份要退出。但「刚点完退出、立刻又双击」时，旧进程还在收尾
    /// （几百毫秒），这时候不能直接判死 —— 先等它一下，不然就会出现「点了没反应」。
    static func waitForPreviousInstance() {
        guard let other = liveInstance() else { return }
        Log.writeSync("检测到正在运行的实例（pid \(other.processIdentifier)），等它退出…")
        var waited = 0
        while waited < 25, liveInstance() != nil {          // 最多等 2.5 秒
            usleep(100_000)
            waited += 1
        }
        if let still = liveInstance() {
            Log.writeSync("已有实例在运行（pid \(still.processIdentifier)），本次启动退出")
            exit(0)
        }
        Log.writeSync("旧实例已退出，本次启动继续")
    }

    private static func liveInstance() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.string255.agentbar")
            .first { $0.processIdentifier != me && !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, PanelActions {
    private let host = TouchBarHost()
    private var statusItem: NSStatusItem?
    private var statusLabel = NSMenuItem(title: "启动中…", action: nil, keyEquivalent: "")
    private var attachLabel = NSMenuItem(title: "Touch Bar", action: nil, keyEquivalent: "")
    private var timer: Timer?
    private var lastTraceTick = 0
    /// 正在退出：这段时间里再点图标会取消退出（见 applicationShouldHandleReopen）
    private var isQuitting = false
    private var quitWork: DispatchWorkItem?

    /// 主线程侧的一份副本，菜单栏和面板都用它，不再各自去扫一遍
    private var current = BarModel(primary: nil, others: [], today: TodayStats(), tick: 0)
    private var lastSignature = ""

    /// 自身 CPU 占用：面板和日志里都显示，方便验证「优化真的生效了」
    private var cpuText = "—"
    private var cpuSample: (at: Date, cpu: Double)?
    private var cpuLastUpdate = Date.distantPast
    private lazy var center = ControlCenter(actions: self)
    private lazy var panelWindow = PanelWindowController(center: center)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        host.start()
        applyBacklight()
        installSignalHandlers()
        observeConfigChanges()

        scheduleTimer()
        // 关闭状态下也要先把面板填好，别显示「读取中…」
        Store.shared.refresh { [weak self] model in self?.apply(model) }

        // 自检：把面板真弹一次再关掉，用来验证 NSPopover + SwiftUI 这条路没崩
        // 新版本第一次启动时自动把面板弹出来 —— 否则「双击了但什么也没出现」太像坏了
        showPanelAfterUpgrade()

        if ProcessInfo.processInfo.environment["AGENTBAR_PANEL_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.openPanel()
                let shown = self?.panelWindow.isVisible ?? false
                Log.write("面板自检：window.isVisible=\(shown)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.panelWindow.close()
                    Log.write("面板自检：已关闭")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                }
            }
        }

        if ProcessInfo.processInfo.environment["AGENTBAR_CALIBRATE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.host.view.beginCalibration()
            }
        }
    }

    /// 版本号变了（升级）就自动弹一次面板，让用户看见「它确实起来了」
    private func showPanelAfterUpgrade() {
        // 只在真正的 .app 里做（直接跑 build 出来的裸二进制时 Bundle 里没有版本号）
        guard Bundle.main.bundleIdentifier != nil else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard AgentBarConfig.lastPanelVersion != version else { return }
        AgentBarConfig.setLastPanelVersion(version)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.openPanel()
            Log.write("新版本 \(version) 首次启动：已弹出控制面板")
        }
    }

    // MARK: - 定时刷新

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = AgentBarConfig.enabled ? AgentBarConfig.refreshSeconds : 5
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard AgentBarConfig.enabled else { return }
        // 扫描在后台串行队列上跑，主线程只负责把结果画出来
        Store.shared.refresh { [weak self] model in
            self?.apply(model)
        }
    }

    /// 主线程：只在「画面真的要变」时才动视图
    private func apply(_ model: BarModel) {
        current = model
        refreshCPU()

        // 状态栏标题和 Touch Bar 用的是同一份数据，签名没变就都别动
        let sig = signature(model)
        guard sig != lastSignature else { return }
        lastSignature = sig
        updateStatusItem(model)

        guard AgentBarConfig.enabled else { return }

        host.view.model = model
        host.view.needsDisplay = true

        if panelWindow.isVisible { pushPanel(model) }
        trace(model)
    }

    /// 一秒一变的东西（耗时、阶段、项目、今日统计）都在里面；
    /// 都不变就不重画——这是省 CPU 的关键。
    private func signature(_ model: BarModel) -> String {
        var parts: [String] = ["r\(AgentBarConfig.revision)"]
        if let p = model.primary {
            parts.append("p|\(p.provider)|\(p.sessionId)|\(p.phase.rawValue)|\(p.project)"
                        + "|\(p.tool ?? "")|\(p.note ?? "")|\(Int(p.elapsed ?? p.turnDuration ?? 0))")
        } else {
            parts.append("p|-")
        }
        for o in model.others {
            parts.append("o|\(o.provider)|\(o.sessionId)|\(o.phase.rawValue)|\(o.project)"
                        + "|\(o.tool ?? "")|\(Int(o.elapsed ?? 0))")
        }
        parts.append("t|\(model.today.turns)|\(Int(model.today.seconds))|\(model.today.tokens ?? 0)"
                    + "|\(Int(model.today.costCNY * 100))|\(Int(model.today.credits * 10))")
        parts.append("a|\(host.view.actionTarget?.sessionId ?? "-")")
        // 变暗后要换高对比配色，档位一变就得重画
        parts.append("d\(TouchBarBacklight.shared.dimmingStep)")
        // 空闲画面里的小内核要动，才需要按帧重画
        if model.primary == nil, AgentBarConfig.structure.showPet {
            parts.append("f\(BarRenderer.petFrame())")
        }
        return parts.joined(separator: " ")
    }

    /// 每 3 秒读一次 getrusage，算这段时间的平均占用
    private func refreshCPU() {
        let now = Date()
        guard now.timeIntervalSince(cpuLastUpdate) >= 3 else { return }
        cpuLastUpdate = now
        let cpu = Self.cpuSeconds()
        if let last = cpuSample {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0 {
                let pct = max(0, (cpu - last.cpu) / dt * 100)
                cpuText = pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
            }
        }
        cpuSample = (now, cpu)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let s = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return u + s
    }

    private func trace(_ model: BarModel) {
        let nowTick = Int(Date().timeIntervalSince1970)
        guard nowTick % 30 == 0, lastTraceTick != nowTick else { return }
        lastTraceTick = nowTick
        let elapsed = model.primary?.elapsed.map { String(Int($0)) } ?? "-"
        Log.write("追踪：状态=\(model.primary?.phase.rawValue ?? "无") 耗时=\(elapsed)s 卡片=\(model.others.count + (model.primary == nil ? 0 : 1)) CPU=\(cpuText)")
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 必须给一个独一无二的名字。用默认的 "Item-0" 会和别的 App 撞名，
        // 系统里那条 "NSStatusItem Visible Item-0 = 0" 会把我们的图标直接判成「隐藏」，
        // 表现就是菜单栏里什么都没有，窗口还被丢到屏幕左上角。
        item.autosaveName = "com.string255.agentbar.status"
        item.isVisible = true
        if let button = item.button {
            // 用彩色图标：菜单栏里一堆单色图标，蓝色闪电更好找
            let symbol = NSImage(systemSymbolName: "bolt.horizontal.fill", accessibilityDescription: "AgentBar")
            if #available(macOS 12.0, *) {
                button.image = symbol?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
            } else {
                button.image = symbol
            }
            button.image?.isTemplate = false
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        // 自检：图标到底有没有出现在菜单栏上。菜单栏挤满时系统会把条目整个藏掉，
        // 这时候窗口为 nil 或落到屏幕外 —— 只能靠量出来。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            let screenW = NSScreen.main?.frame.width ?? 0
            let visible = self.statusItem?.isVisible ?? false
            let frame = button.window?.frame
            let pos = frame.map { "(\(Int($0.minX)),\(Int($0.minY)))" } ?? "无窗口"
            Log.write("状态栏项：isVisible=\(visible) 位置=\(pos) 屏幕宽=\(Int(screenW))")
            if !visible {
                Log.write("状态栏项被系统隐藏了：检查 com.apple.controlcenter 里的 NSStatusItem Visible 键，或菜单栏是否已满")
            }
        }
    }

    /// 左键开面板，右键给一份「老式菜单」（喜欢直接点的可以走这条）
    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showClassicMenu()
            return
        }
        togglePanel()
    }

    private func showClassicMenu() {
        let menu = buildMenu()
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil          // 立刻摘掉，否则左键就再也打不开面板了
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        statusLabel.isEnabled = false
        attachLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(attachLabel)
        menu.addItem(.separator())

        let enable = NSMenuItem(title: AgentBarConfig.enabled ? "关闭 AgentBar" : "开启 AgentBar",
                                action: #selector(toggleEnabled), keyEquivalent: "e")
        enable.target = self
        menu.addItem(enable)
        menu.addItem(.separator())

        for (title, sel, key) in [("打开控制面板", #selector(openPanel), "p"),
                                 ("保持 Touch Bar 常亮", #selector(toggleKeepLit), "l"),
                                 ("重新挂载 Touch Bar", #selector(reattach), "r"),
                                 ("校准右侧边界（点一下最右可用位置）", #selector(calibrate), "k"),
                                 ("恢复被隐藏 / 归档的项目", #selector(restoreHidden), ""),
                                 ("导出预览图…", #selector(exportPreview), ""),
                                 ("打开状态目录", #selector(openStateDir), "o")] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.target = self
            if sel == #selector(toggleKeepLit) {
                item.state = AgentBarConfig.keepLit ? .on : .off
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AgentBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func updateStatusItem(_ model: BarModel) {
        let enabled = AgentBarConfig.enabled
        let attached = host.isAttached
        attachLabel.title = attached ? "Touch Bar：已接管" : "Touch Bar：未接管（仅菜单栏）"

        guard let button = statusItem?.button else { return }
        button.appearsDisabled = !enabled

        guard enabled else {
            statusLabel.title = "已暂停"
            button.title = AgentBarConfig.menuTitle ? " 已暂停" : ""
            return
        }

        var title = ""
        if let primary = model.primary, primary.isLive || primary.phase == .done {
            let elapsed = primary.elapsed.map { " " + clockText($0) } ?? ""
            statusLabel.title = "\(primary.phase.label)\(elapsed) · \(primary.project)"
            title = AgentBarConfig.menuTitle ? " \(primary.phase.label)\(elapsed)" : ""
        } else if model.today.isEmpty {
            statusLabel.title = "暂无 AI 活动"
        } else {
            statusLabel.title = "今日 \(model.today.turns) 轮 · \(model.today.durationText)"
            title = AgentBarConfig.menuTitle ? " \(model.today.durationText)" : ""
        }
        // 改 title 会让菜单栏重新排布，没变就别碰
        if button.title != title { button.title = title }
    }

    // MARK: - 控制面板

    private func togglePanel() {
        center.refreshFromConfig()
        center.attached = host.isAttached
        pushPanel(current)
        panelWindow.toggle()
    }

    @objc private func openPanel() {
        center.refreshFromConfig()
        center.attached = host.isAttached
        pushPanel(current)
        panelWindow.show()
    }

    private func pushPanel(_ model: BarModel) {
        center.model = model
        center.attached = host.isAttached
        center.cpu = cpuText
        center.enabled = AgentBarConfig.enabled
        center.revision = AgentBarConfig.revision
        center.keepLitStatus = TouchBarBacklight.shared.statusText
        center.keepLitNeedsPermission = TouchBarBacklight.shared.state == .needsPermission

        if let p = model.primary {
            let elapsed = (p.elapsed ?? p.turnDuration).map { " · " + clockText($0) } ?? ""
            center.statusLine = "\(p.phase.label)\(elapsed) · \(p.project)"
            var detail = providerShort(p.provider)
            if let tool = p.tool, !tool.isEmpty, p.phase != .done { detail += " · \(tool)" }
            if model.others.count > 0 { detail += " · 另外 \(model.others.count) 个会话" }
            center.detailLine = detail
        } else if model.today.isEmpty {
            center.statusLine = "暂无 AI 活动"
            center.detailLine = ""
        } else {
            center.statusLine = "今日 \(model.today.turns) 轮 · \(model.today.durationText)"
            var detail = ""
            if let tok = model.today.tokensText { detail = tok }
            if let cost = model.today.costText { detail += detail.isEmpty ? cost : " · " + cost }
            center.detailLine = detail
        }
    }

    private func observeConfigChanges() {
        NotificationCenter.default.addObserver(forName: .agentBarConfigChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            self.scheduleTimer()
            // 配置一变就得重画（主题/结构），并且让 Touch Bar 立刻跟上
            self.lastSignature = ""
            BarRenderer.clearCaches()
            self.applyBacklight()
            if AgentBarConfig.enabled {
                self.host.present()
                self.tick()
            } else {
                self.host.dismiss()
                self.updateStatusItem(self.current)
            }
        }
    }

    // MARK: - 常亮

    /// 只有「接管着 + 常亮开着」才保活；其余时候一次私有调用都不发
    private func applyBacklight() {
        let keep = AgentBarConfig.enabled && AgentBarConfig.keepLit
        let backlight = TouchBarBacklight.shared
        if keep { backlight.start() } else { backlight.stop() }
        center.keepLit = AgentBarConfig.keepLit
        center.keepLitStatus = backlight.statusText
        center.keepLitNeedsPermission = backlight.state == .needsPermission
    }

    @objc private func toggleKeepLit() {
        AgentBarConfig.keepLit.toggle()
        applyBacklight()
        Log.write("常亮：\(AgentBarConfig.keepLit ? "已开启" : "已关闭")")
    }

    // MARK: - 菜单动作

    @objc private func toggleEnabled() {
        AgentBarConfig.enabled.toggle()
        center.enabled = AgentBarConfig.enabled
    }

    @objc private func reattach() {
        lastSignature = ""
        host.dismiss()
        _ = host.present(force: true)
    }

    @objc private func calibrate() {
        host.view.beginCalibration()
    }

    @objc private func restoreHidden() {
        AgentBarConfig.unhideAll()
        AgentBarConfig.setFocus(nil)
        lastSignature = ""
        Log.write("已恢复全部隐藏/归档的项目")
    }

    @objc private func exportPreview() {
        let path = NSHomeDirectory() + "/Desktop/agentbar-preview.png"
        CLI.writePNG(model: current, to: path)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openStateDir() {
        Paths.ensure()
        NSWorkspace.shared.open(Paths.stateDir)
    }

    @objc private func openLog() {
        Paths.ensure()
        if FileManager.default.fileExists(atPath: Log.url.path) {
            NSWorkspace.shared.open(Log.url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.root])
        }
    }

    @objc private func quit() {
        gracefulExit()
    }

    /// 正常退出或被 kill 时都要把 Touch Bar 还回去，
    /// 否则系统会把最后一帧冻在屏幕上（看起来像卡住了）。
    /// 退出：留 1 秒「反悔窗口」。
    /// 系统在 App 刚结束的几百毫秒里会回 -609（应用不可用），
    /// 用户「点退出 → 马上又双击」时会撞上，表现就是「点了没反应」。
    /// 这一秒内再点图标 = 取消退出、把窗口还回来；过了这一秒才真正退出。
    func gracefulExit() {
        guard quitWork == nil else { return }
        isQuitting = true
        host.stop()
        TouchBarBacklight.shared.stop()
        Log.write("退出：已收起 Touch Bar（1 秒内再点图标可取消）")
        statusItem?.isVisible = false

        let work = DispatchWorkItem {
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        }
        quitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// 取消正在进行的退出
    private func cancelQuit() {
        quitWork?.cancel()
        quitWork = nil
        isQuitting = false
        statusItem?.isVisible = true
        host.present(force: true)
        lastSignature = ""
        tick()
        openPanel()
        Log.write("已取消退出，窗口已恢复")
    }

    /// 已经在跑的时候，用户在访达里再双击一次 → 把窗口拉到前面来（不再「点了没反应」）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isQuitting {
            // 退出倒计时里又点了一次 → 用户其实是想把它叫回来
            cancelQuit()
            return true
        }
        openPanel()
        return true
    }

    /// 关掉窗口不等于退出：继续待在菜单栏
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        TouchBarBacklight.shared.stop()
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

    // MARK: - PanelActions

    func panelSetEnabled(_ on: Bool) {
        if AgentBarConfig.enabled != on { AgentBarConfig.enabled = on }
        center.enabled = on
        lastSignature = ""
        applyBacklight()
        if on {
            host.present(force: true)
            tick()
        } else {
            host.dismiss()
        }
        updateStatusItem(current)
    }

    func panelRemount() {
        reattach()
    }

    func panelCalibrate() {
        calibrate()
    }

    func panelRestoreHidden() {
        restoreHidden()
    }

    func panelExportPreview() {
        exportPreview()
    }

    func panelOpenStateDir() {
        openStateDir()
    }

    func panelOpenLog() {
        openLog()
    }

    func panelQuit() {
        gracefulExit()
    }

    func panelSetKeepLit(_ on: Bool) -> String {
        if AgentBarConfig.keepLit != on { AgentBarConfig.keepLit = on }
        applyBacklight()
        return TouchBarBacklight.shared.statusText
    }

    func panelOpenAccessibilitySettings() {
        TouchBarBacklight.shared.openAccessibilitySettings()
        Log.write("常亮：已打开「辅助功能」设置面板")
    }

    func panelAutostart(_ on: Bool) -> Bool {
        LaunchAgent.setEnabled(on)
    }

    func panelIsAutostart() -> Bool {
        LaunchAgent.isEnabled
    }

    func panelRefreshNow() {
        lastSignature = ""
        tick()
    }
}

extension URL {
    var isFileExisting: Bool { FileManager.default.fileExists(atPath: path) }
}
