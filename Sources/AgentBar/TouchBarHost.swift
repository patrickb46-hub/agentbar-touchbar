import AppKit
import ObjectiveC

/// 用私有 system-modal 接口接管 Touch Bar：
///   +[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]
///   +[NSTouchBar dismissSystemModalTouchBar:]
///   DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL)   ← DFRFoundation
///
/// 所有私有符号都做存在性判断，缺一个就降级为「只在菜单栏显示」，绝不崩。
final class TouchBarHost: NSObject, NSTouchBarDelegate {

    private let mainId = NSTouchBarItem.Identifier("app.agentbar.main")
    private var touchBar: NSTouchBar?
    private var dfrHandle: UnsafeMutableRawPointer?

    let view = BarView(frame: NSRect(x: 0, y: 0, width: 1000, height: BarStyle.height))

    private(set) var isAttached = false
    private var reportedMissing = false
    private var didLogAttach = false

    private var started = false
    private var cachedItem: NSCustomTouchBarItem?
    private var watchdog: Timer?

    func start() {
        guard !started else { return }
        started = true
        loadPrivateFrameworks()
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [mainId]
        touchBar = bar

        present()
        observeSystemEvents()

        // 自检：present 返回成功不代表真的画上去了，3 秒后验证一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, AgentBarConfig.enabled else { return }
            if self.view.hasDrawn {
                Log.write("自检通过：视图已绘制")
            } else {
                Log.write("自检失败：present 成功但视图未绘制，重试")
                _ = self.present(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    Log.write(self.view.hasDrawn ? "重试成功" : "重试仍失败，仅菜单栏可用")
                }
            }
        }

        // 系统在某些转场里会收回 modal bar。
        // 这里只是「看一眼还在不在」，真在的时候一次私有调用都不发，
        // 免得每 4 秒把 Touch Bar 重挂一遍（会闪、也费 CPU）。
        watchdog = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.verifyAttached()
        }
        if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        dismiss()
    }

    /// 只在「确实没挂上」时才重新 present
    @discardableResult
    func verifyAttached() -> Bool {
        guard AgentBarConfig.enabled else { return false }
        guard isAttached, view.hasDrawn, view.window != nil else {
            if isAttached { Log.write("Touch Bar 掉线，重新挂载") }
            return present(force: true)
        }
        return true
    }

    // MARK: - 私有符号

    private func loadPrivateFrameworks() {
        let path = "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"
        dfrHandle = dlopen(path, RTLD_NOW)
        if dfrHandle == nil {
            Log.write("DFRFoundation 未加载（系统可能已移除），关闭按钮抑制不可用")
            return
        }
        if let handle = dfrHandle,
           let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") {
            typealias Fn = @convention(c) (Bool) -> Void
            unsafeBitCast(sym, to: Fn.self)(false)
            Log.write("DFRSystemModalShowsCloseBoxWhenFrontMost 已生效")
        } else {
            Log.write("DFR 符号缺失，跳过关闭按钮抑制")
        }
    }

    @discardableResult
    func present(force: Bool = false) -> Bool {
        guard AgentBarConfig.enabled else { return false }
        if !force, isAttached, view.window != nil, view.hasDrawn { return true }

        guard let bar = touchBar, let cls = NSClassFromString("NSTouchBar") else { return false }
        let sel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        guard let method = class_getClassMethod(cls, sel) else {
            if !reportedMissing {
                reportedMissing = true
                Log.write("系统缺少 presentSystemModalTouchBar:placement:systemTrayItemIdentifier:，降级为菜单栏模式")
            }
            return false
        }

        // 注意：release 优化下用 AnyClass 传第一个参数会被错误地装箱，
        // 必须退化成裸指针（IMP 的第一个参数就是 self/metaclass 指针）。
        typealias Fn = @convention(c) (UnsafeMutableRawPointer, Selector, NSTouchBar, Int, NSString?) -> Void
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: Fn.self)
        let receiver = unsafeBitCast(cls, to: UnsafeMutableRawPointer.self)
        fn(receiver, sel, bar, 0, nil)

        isAttached = true
        if !didLogAttach {
            didLogAttach = true
            Log.write("Touch Bar 已接管（modal placement=0）")
        }
        return true
    }

    func dismiss() {
        guard let bar = touchBar, let cls = NSClassFromString("NSTouchBar") else { return }
        let sel = NSSelectorFromString("dismissSystemModalTouchBar:")
        guard let method = class_getClassMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (UnsafeMutableRawPointer, Selector, NSTouchBar) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        fn(unsafeBitCast(cls, to: UnsafeMutableRawPointer.self), sel, bar)
        isAttached = false
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == mainId else { return nil }
        // 系统可能多次来要 item；必须复用同一个实例，
        // 否则同一个 view 会在两个 item 之间被搬走，终态可能挂到不显示的那个。
        if let cachedItem { return cachedItem }

        let item = NSCustomTouchBarItem(identifier: identifier)
        let width = AgentBarConfig.rulerMode ? AgentBarConfig.rulerWidth : AgentBarConfig.barWidth
        view.translatesAutoresizingMaskIntoConstraints = false
        let wc = view.widthAnchor.constraint(equalToConstant: width)
        wc.isActive = true
        view.widthConstraint = wc
        view.heightAnchor.constraint(equalToConstant: BarStyle.height).isActive = true
        item.view = view
        cachedItem = item
        Log.write("创建 Touch Bar item（宽度 \(Int(width))）")
        return item
    }

    // MARK: - 重挂时机

    private func observeSystemEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.verifyAttached()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.verifyAttached()
        }
    }
}
