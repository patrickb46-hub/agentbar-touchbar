import AppKit

final class BarView: NSView {
    var model = BarModel(primary: nil, others: [], today: TodayStats(), tick: 0)
    var widthConstraint: NSLayoutConstraint?

    private var hitLayout = BarLayout()
    private var didLogSize = false
    private var calibrating = false

    func beginCalibration() {
        calibrating = true
        needsDisplay = true
        Log.write("进入右侧边界校准")
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Touch Bar 走的是 touch 事件通道，不打开这个收不到点击
        allowedTouchTypes = [.indirect, .direct]
        wantsRestingTouches = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowedTouchTypes = [.indirect, .direct]
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

        // 右侧被控制条盖住的一段要扣掉，否则内容会被裁
        BarStyle.background.setFill()
        bounds.fill()
        let contentWidth = max(200, bounds.width - AgentBarConfig.reservedRight)
        let contentRect = NSRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        hitLayout = BarRenderer.draw(model, in: contentRect)
    }

    // MARK: - 点击（两种事件通道都接）

    override func mouseDown(with event: NSEvent) {
        handleTap(at: convert(event.locationInWindow, from: nil), source: "mouse")
    }

    override func touchesBegan(with event: NSEvent) {
        let touches = event.touches(matching: .began, in: self)
        guard let first = touches.first else { return }
        handleTap(at: first.location(in: self), source: "touch")
    }

    private func handleTap(at point: NSPoint, source: String) {
        Log.write("点击 \(source) at (\(Int(point.x)), \(Int(point.y)))  卡片 \(hitLayout.cards.count) 个")

        // 校准模式：点的位置就是可用区域的右边界
        if calibrating {
            let usable = max(200, min(bounds.width, point.x))
            AgentBarConfig.setReservedRight(bounds.width - usable)
            calibrating = false
            needsDisplay = true
            Log.write("校准完成：可用宽度 \(Int(usable))，右侧保留 \(Int(bounds.width - usable))")
            return
        }

        if let rect = hitLayout.approvalRect, rect.contains(point) {
            openPrimary()
            return
        }
        for card in hitLayout.cards where card.rect.contains(point) {
            open(url: card.url, cwd: card.cwd)
            return
        }
        Log.write("点击位置没有命中任何区域")
    }

    private func openPrimary() {
        guard let primary = model.primary else { return }
        open(url: primary.jumpUrl, cwd: primary.cwd)
    }

    /// 优先用深链跳回具体会话；没有可用的 scheme 就打开项目目录
    private func open(url: String?, cwd: String?) {
        if let raw = url, let u = URL(string: raw), let scheme = u.scheme,
           NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
            NSWorkspace.shared.open(u)
            Log.write("跳转 \(scheme):// \(u.path)")
            return
        }
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            Log.write("打开目录 \(cwd)")
            return
        }
        Log.write("没有可用的跳转目标（url=\(url ?? "nil"), cwd=\(cwd ?? "nil")）")
    }
}
