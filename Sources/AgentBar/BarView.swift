import AppKit

final class BarView: NSView {
    var model = BarModel(primary: nil, others: [], today: TodayStats(), tick: 0)
    var widthConstraint: NSLayoutConstraint?

    /// 长按某个卡片后进入的操作态
    var actionTarget: AgentSnapshot?

    private var hitLayout = BarLayout()
    private var didLogSize = false
    var hasDrawn: Bool { didLogSize }
    private var calibrating = false
    private var pressStart: (point: NSPoint, at: Date)?

    private let longPressSeconds: TimeInterval = 0.55

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.indirect, .direct]
        wantsRestingTouches = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowedTouchTypes = [.indirect, .direct]
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func beginCalibration() {
        calibrating = true
        needsDisplay = true
        Log.write("进入右侧边界校准")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        adoptPanelWidth()
    }

    override func layout() {
        super.layout()
        adoptPanelWidth()
    }

    /// 真实可用宽度由 _NSFunctionRowPanel 决定，不同机型不一样，
    /// 直接读窗口尺寸自适应，不写死数字。
    private func adoptPanelWidth() {
        guard let constraint = widthConstraint,
              let panelWidth = window?.frame.width,
              panelWidth > 200 else { return }
        if abs(constraint.constant - panelWidth) > 0.5 {
            constraint.constant = panelWidth
            Log.write("面板宽度实测 \(Int(panelWidth))，已适配布局")
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !didLogSize {
            didLogSize = true
            let windowDesc = window.map { "\(type(of: $0)) frame=\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "无 window"
            let superDesc = superview.map { "\(type(of: $0)) bounds=\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "无 superview"
            Log.write("实测：view bounds=\(Int(bounds.width))x\(Int(bounds.height)) | \(superDesc) | \(windowDesc)")
        }

        if AgentBarConfig.rulerMode || calibrating {
            BarRenderer.drawRuler(in: bounds)
            return
        }

        BarStyle.background.setFill()
        bounds.fill()
        let contentWidth = max(200, bounds.width - AgentBarConfig.reservedRight)
        let contentRect = NSRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        hitLayout = BarRenderer.draw(model, in: contentRect, action: actionTarget)
    }

    // MARK: - 触摸：短按=点击，长按=操作菜单

    override func touchesBegan(with event: NSEvent) {
        guard let touch = event.touches(matching: .began, in: self).first else { return }
        let point = touch.location(in: self)

        // 操作行里按下即生效
        if actionTarget != nil {
            performAction(at: point)
            return
        }
        pressStart = (point, Date())
    }

    override func touchesEnded(with event: NSEvent) {
        defer { pressStart = nil }
        guard let start = pressStart else { return }
        let point = event.touches(matching: .ended, in: self).first?.location(in: self) ?? start.point
        resolvePress(from: start, to: point, source: "touch")
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if actionTarget != nil {
            performAction(at: point)
            return
        }
        pressStart = (point, Date())
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressStart = nil }
        guard let start = pressStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        resolvePress(from: start, to: point, source: "mouse")
    }

    private func resolvePress(from start: (point: NSPoint, at: Date), to point: NSPoint, source: String) {
        let duration = Date().timeIntervalSince(start.at)
        let moved = hypot(point.x - start.point.x, point.y - start.point.y)

        if calibrating {
            let usable = max(200, min(bounds.width, point.x))
            AgentBarConfig.setReservedRight(bounds.width - usable)
            calibrating = false
            needsDisplay = true
            Log.write("校准完成：可用宽度 \(Int(usable))，右侧保留 \(Int(bounds.width - usable))")
            return
        }

        if duration >= longPressSeconds, moved < 30 {
            if let card = hitLayout.cards.first(where: { $0.rect.contains(point) }) {
                actionTarget = card.snapshot
                needsDisplay = true
                Log.write("长按：\(card.snapshot.project)")
                return
            }
        }
        handleTap(at: point, source: source)
    }

    private func handleTap(at point: NSPoint, source: String) {
        Log.write("点击 \(source) at (\(Int(point.x)), \(Int(point.y)))  卡片 \(hitLayout.cards.count) 个")

        if let rect = hitLayout.exitFocusRect, rect.contains(point) {
            AgentBarConfig.setFocus(nil)
            Log.write("退出单卡聚焦")
            needsDisplay = true
            return
        }
        if let rect = hitLayout.approvalRect, rect.contains(point) {
            openPrimary()
            return
        }
        for card in hitLayout.cards where card.rect.contains(point) {
            open(url: card.url, cwd: card.cwd, app: card.snapshot.jumpApp)
            return
        }
    }

    // MARK: - 操作行

    private func performAction(at point: NSPoint) {
        guard let target = actionTarget else { return }
        guard let hit = hitLayout.actions.first(where: { $0.rect.contains(point) }) else {
            actionTarget = nil
            needsDisplay = true
            return
        }

        let key = Store.key(target)
        switch hit.kind {
        case .focus:
            AgentBarConfig.setFocus(key)
            Log.write("聚焦：\(target.project)")
        case .hide:
            AgentBarConfig.hide(key, hours: 2)
            Log.write("隐藏 2 小时：\(target.project)")
        case .archive:
            AgentBarConfig.archive(key)
            Log.write("归档：\(target.project)")
        case .cancel:
            Log.write("取消操作：\(target.project)")
        }
        actionTarget = nil
        needsDisplay = true
    }

    private func openPrimary() {
        guard let primary = model.primary else { return }
        open(url: primary.jumpUrl, cwd: primary.cwd, app: primary.jumpApp)
    }

    /// 优先用深链跳回具体会话；没有可用的 scheme 就打开项目目录
    private func open(url: String?, cwd: String?, app: String? = nil) {
        if let raw = url, let u = URL(string: raw), let scheme = u.scheme,
           NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
            NSWorkspace.shared.open(u)
            Log.write("跳转 \(scheme):// \(u.path)")
            return
        }
        // 没有深链的 CLI 类工具：优先把它的宿主应用切到前台
        if let app {
            let bundle = URL(fileURLWithPath: "/Applications/\(app).app")
            if FileManager.default.fileExists(atPath: bundle.path) {
                NSWorkspace.shared.openApplication(at: bundle, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { Log.write("激活 \(app) 失败：\(error.localizedDescription)") }
                    else { Log.write("激活 \(app)") }
                }
                return
            }
        }
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            Log.write("打开目录 \(cwd)")
            return
        }
        Log.write("没有可用的跳转目标（url=\(url ?? "nil"), cwd=\(cwd ?? "nil")）")
    }
}
