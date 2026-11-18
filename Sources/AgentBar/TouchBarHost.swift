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
    private var lastAttach = Date.distantPast
    private var reportedMissing = false
    private var didLogAttach = false

    func start() {
        loadPrivateFrameworks()
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [mainId]
        touchBar = bar

        present()
        observeSystemEvents()

        // 系统在某些转场里会收回 modal bar，定时幂等重挂
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.present()
        }
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
    func present() -> Bool {
        guard let bar = touchBar, let cls = NSClassFromString("NSTouchBar") else { return false }
        let sel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        guard let method = class_getClassMethod(cls, sel) else {
            if !reportedMissing {
                reportedMissing = true
                Log.write("系统缺少 presentSystemModalTouchBar:placement:systemTrayItemIdentifier:，降级为菜单栏模式")
            }
            return false
        }

        typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar, Int, NSString?) -> Void
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(cls, sel, bar, 0, nil)

        isAttached = true
        lastAttach = Date()
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
        typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(cls, sel, bar)
        isAttached = false
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == mainId else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let width = AgentBarConfig.rulerMode ? AgentBarConfig.rulerWidth : AgentBarConfig.barWidth
        view.translatesAutoresizingMaskIntoConstraints = false
        let wc = view.widthAnchor.constraint(equalToConstant: width)
        wc.isActive = true
        view.widthConstraint = wc
        view.heightAnchor.constraint(equalToConstant: BarStyle.height).isActive = true
        item.view = view
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
                self?.present()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.present()
        }
    }
}
