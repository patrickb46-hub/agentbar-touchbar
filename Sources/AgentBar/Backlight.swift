import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ObjectiveC

/// 让 Touch Bar 不走进「闲置 → 变暗 → 熄灭」这条路径。
///
/// 系统默认：停手约 60 秒后分档调暗（实测档位 0→1→2→4，20 秒走完），再久一点彻底熄灭，
/// 得先摸一下才亮回来。没有公开开关。两条路，按可用性依次降级：
///
/// **一、写背光档位（首选）** —— `DFRBrightness.framework` 的 `DFRBrightnessClient`：
///
///     -getDFRDisplayID                               拿 Touch Bar 的显示句柄
///     -getDimmingStep                                当前调光档位（0 = 原亮度）
///     -dimToStep:                                    把档位调到指定值
///     -turnOn                                        整体点亮
///     -registerDisplayStateUpdateCallbackWithBlock:  亮灭变化回调（1 = 灭，2 = 亮）
///     -scheduleWithDispatchQueue:                    挂到指定队列
///
/// 每 0.5 秒读一次档位，被调暗就按回 0、被关掉就 turnOn。
///
/// **二、模拟输入保活（降级）** —— 系统不给句柄时（`getDFRDisplayID` 返回 -1，
/// 本机 2018 款 15 寸 Intel + macOS 15.8 就是这种情况），改走这条路：
/// 闲置够久就往 HID 里投一个零位移鼠标事件，把闲置计时器顶回去。
/// 需要「辅助功能」权限，没有就老老实实报「需要授权」并引导去开。
///
/// 两条路都遵守同一条铁律：主屏睡着、屏幕锁着时彻底停手 —— 那会儿变暗是应该的。
/// 拆开开关时把接管前的档位还回去。
final class TouchBarBacklight {

    static let shared = TouchBarBacklight()

    enum State: Equatable {
        case idle                    // 没开
        case running                 // 生效中
        case needsPermission         // 降级路要授权
        case unavailable(String)     // 两条路都走不通

        var isRunning: Bool { self == .running }

        var unavailableReason: String? {
            if case .unavailable(let why) = self { return why }
            return nil
        }
    }

    /// 当前在用哪条路
    enum Mechanism: String {
        case idle = "未启用"
        case brightness = "背光档位"
        case synthetic = "模拟输入"
    }

    private(set) var state: State = .idle
    private(set) var mechanism: Mechanism = .idle
    private(set) var displayID: UInt32 = 0
    /// 当前调光档位（0 = 原亮度）。哪怕没句柄也读得到，所以「暗屏也能读」也靠它。
    private(set) var dimmingStep: Int64 = 0
    private(set) var undimCount = 0
    private(set) var wakeCount = 0
    private(set) var pushCount = 0

    private var client: NSObject?
    private var timer: Timer?
    private var permissionPoll: Timer?
    private var started = false
    /// 接管前的调光档位，关闭时还回去
    private var originalStep: Int64 = 0
    /// 面板亮灭（1 = 灭，2 = 亮），只在私有回调里更新
    private var panelState: Int64 = 2
    private let stateLock = NSLock()

    /// 屏幕锁定状态不必每 0.5 秒问一次，两秒一次够了
    private var locked = false
    private var lockCheckedAt = Date.distantPast
    /// 拿不到句柄 / 没权限时的重试计数
    private var retries = 0
    /// 系统授权弹窗每次运行最多弹一次，别反复烦人
    private var didPromptForAccessibility = false
    /// 写入被系统拒之后的冷却时间点
    private var nextActionAt = Date.distantPast

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/DFRBrightness.framework/DFRBrightness"

    private enum Sel {
        static let displayID = NSSelectorFromString("getDFRDisplayID")
        static let dimmingStep = NSSelectorFromString("getDimmingStep")
        static let dimToStep = NSSelectorFromString("dimToStep:")
        static let turnOn = NSSelectorFromString("turnOn")
        static let initializeHID = NSSelectorFromString("initializeHID")
        static let schedule = NSSelectorFromString("scheduleWithDispatchQueue:")
        static let stateCallback = NSSelectorFromString("registerDisplayStateUpdateCallbackWithBlock:")
    }

    private typealias BoolNoArg = @convention(c) (AnyObject, Selector) -> Bool
    private typealias UInt32NoArg = @convention(c) (AnyObject, Selector) -> UInt32
    private typealias Int64NoArg = @convention(c) (AnyObject, Selector) -> Int64
    private typealias BoolInt64 = @convention(c) (AnyObject, Selector, Int64) -> Bool
    private typealias VoidQueue = @convention(c) (AnyObject, Selector, DispatchQueue) -> Void
    private typealias BoolBlock = @convention(c) (AnyObject, Selector,
                                                  @convention(block) (Int64) -> Void) -> Bool

    // MARK: - 开关

    func start() {
        guard !started else { return }
        started = true
        undimCount = 0
        wakeCount = 0
        pushCount = 0

        guard let obj = loadFramework() ? makeClient() : nil else {
            retryLater(state.unavailableReason ?? "拿不到 DFRBrightnessClient")
            return
        }
        client = obj

        // 句柄拿不到时先补一次 initializeHID 再问 —— 有的系统要初始化过 HID 才肯给
        var id = readDisplayID()
        if id == 0 || id == UInt32.max, implementation(Sel.initializeHID) != nil {
            _ = callBoolNoArg(Sel.initializeHID)
            id = readDisplayID()
        }
        displayID = id
        dimmingStep = readDimmingStep()

        if id != 0, id != UInt32.max {
            startBrightnessPath(id: id)
        } else {
            startSyntheticPath()
        }
    }

    /// 首选：直接写背光档位
    private func startBrightnessPath(id: UInt32) {
        mechanism = .brightness
        scheduleClient()
        registerStateCallback()

        originalStep = readDimmingStep()
        retries = 0
        state = .running
        Log.write("常亮：已接管背光 —— displayID=\(id) 起始档位=\(originalStep) 面板状态=\(currentPanelState)")
        startTimer()
    }

    /// 降级：投模拟输入。要辅助功能权限，没有就等授权
    private func startSyntheticPath() {
        mechanism = .synthetic
        guard AXIsProcessTrusted() else {
            state = .needsPermission
            Log.write("常亮：系统没给显示句柄，改用模拟输入保活；需要「辅助功能」权限，等授权")
            promptForAccessibility()
            waitForPermission()
            return
        }
        retries = 0
        state = .running
        Log.write("常亮：系统没给显示句柄，改用模拟输入保活（辅助功能已授权）")
        startTimer()
    }

    func stop() {
        guard started || timer != nil || permissionPoll != nil else { return }
        started = false
        timer?.invalidate()
        timer = nil
        permissionPoll?.invalidate()
        permissionPoll = nil

        // 把档位还回去，让系统的正常行为接着生效（免得留下一个被我们改过的亮度）
        if state.isRunning, mechanism == .brightness, originalStep > 0 {
            _ = setStep(originalStep)
        }
        client = nil
        state = .idle
        mechanism = .idle
        Log.write("常亮：已关闭（拉回 \(undimCount) 次、点亮 \(wakeCount) 次、模拟输入 \(pushCount) 次）")
    }

    /// 登录初期系统服务可能还没起来 —— 隔 10 秒再试，最多 3 次
    private func retryLater(_ why: String) {
        started = false
        state = .unavailable(why)
        guard retries < 3 else {
            Log.write("常亮：不可用 —— \(why)；重试 3 次仍不行，本次运行不再尝试")
            return
        }
        retries += 1
        Log.write("常亮：\(why)，10 秒后重试（\(retries)/3）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.started, AgentBarConfig.enabled, AgentBarConfig.keepLit else { return }
            self.start()
        }
    }

    /// 面板/菜单栏上那句话
    var statusText: String {
        switch state {
        case .idle:
            return "未开启"
        case .needsPermission:
            return "需要「辅助功能」权限才能保活"
        case .unavailable(let why):
            return "本机不可用 · \(why)"
        case .running:
            switch mechanism {
            case .synthetic:
                return pushCount == 0 ? "生效中（模拟输入）· 还没需要干预"
                                      : "生效中（模拟输入）· 顶回 \(pushCount) 次"
            case .brightness:
                if undimCount == 0 && wakeCount == 0 { return "生效中 · 还没需要干预" }
                return "生效中 · 拉回 \(undimCount) 次 / 点亮 \(wakeCount) 次"
            case .idle:
                return "生效中"
            }
        }
    }

    /// 现在面板是不是已经暗了（给渲染器用来切高对比配色）
    var isDimmed: Bool { dimmingStep >= 2 }

    // MARK: - 保活循环

    private func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard started, state.isRunning else { return }
        // 主屏睡着 / 屏幕锁着都不插手：那会儿变暗是应该的
        guard displayIsAwake, !isScreenLocked else { return }

        if client != nil {
            dimmingStep = readDimmingStep()
        }

        switch mechanism {
        case .brightness:
            // 上一次写被系统拒了就缓 2 秒再试，别每半秒去敲一次
            guard Date() >= nextActionAt else { return }
            if dimmingStep > 0 {
                if setStep(0) {
                    undimCount += 1
                    if undimCount == 1 || undimCount % 20 == 0 {
                        Log.write("常亮：面板被调暗到档位 \(dimmingStep)，已按回 0（累计 \(undimCount) 次）")
                    }
                } else {
                    nextActionAt = Date().addingTimeInterval(2)
                }
            }
            if currentPanelState == 1 {
                if turnOnPanel() {
                    wakeCount += 1
                    Log.write("常亮：面板被熄灭，已重新点亮（累计 \(wakeCount) 次）")
                } else {
                    nextActionAt = Date().addingTimeInterval(2)
                }
            }

        case .synthetic:
            // 闲置够久才推一次；正在用的时候系统本来就不会暗
            guard idleSeconds >= 25 else { return }
            // 先记下来再推 —— 推完闲置时间立刻归零，事后再读就永远是 0 了
            let idleBefore = Int(idleSeconds)
            pushActivity()
            pushCount += 1
            if pushCount == 1 || pushCount % 20 == 0 {
                Log.write("常亮：闲置 \(idleBefore)s，已投模拟输入（累计 \(pushCount) 次，当前档位 \(dimmingStep)）")
            }

        case .idle:
            return
        }
    }

    /// 往 HID 里丢一个零位移鼠标移动：不点、不挪光标，只把闲置计时器顶回去
    private func pushActivity() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: location, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// 距上一次「真输入」多少秒。取几种常见事件里最近的那个 ——
    /// 不依赖 kCGAnyInputEventType（Swift 里拿不到这个值）。
    private var idleSeconds: Double {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    // MARK: - 辅助功能权限

    func isAccessibilityGranted() -> Bool { AXIsProcessTrusted() }

    /// 把系统弹窗/设置面板叫出来，用户只要勾一下
    func promptForAccessibility() {
        guard !didPromptForAccessibility else { return }
        didPromptForAccessibility = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// 用户可能在设置里勾上，所以每 2 秒看一眼，一旦到手就立刻接管
    private func waitForPermission() {
        guard permissionPoll == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard AXIsProcessTrusted() else { return }
            self.permissionPoll?.invalidate()
            self.permissionPoll = nil
            guard AgentBarConfig.enabled, AgentBarConfig.keepLit else { return }
            Log.write("常亮：「辅助功能」权限已到手，重新接管")
            self.started = false
            self.start()
        }
        RunLoop.main.add(t, forMode: .common)
        permissionPoll = t
    }

    // MARK: - 主屏状态

    private var displayIsAwake: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    private var isScreenLocked: Bool {
        let now = Date()
        if now.timeIntervalSince(lockCheckedAt) >= 2 {
            lockCheckedAt = now
            if let raw = CGSessionCopyCurrentDictionary(),
               let info = raw as? [String: Any] {
                locked = (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
            } else {
                locked = false
            }
        }
        return locked
    }

    private var currentPanelState: Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return panelState
    }

    // MARK: - 私有接口的薄封装

    private func loadFramework() -> Bool {
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil else {
            state = .unavailable("DFRBrightness 加载失败")
            Log.write("常亮：DFRBrightness.framework 加载失败")
            return false
        }
        guard NSClassFromString("DFRBrightnessClient") != nil else {
            state = .unavailable("系统里没有 DFRBrightnessClient")
            Log.write("常亮：找不到 DFRBrightnessClient 类")
            return false
        }
        return true
    }

    private func makeClient() -> NSObject? {
        guard let cls = NSClassFromString("DFRBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }

    private func implementation(_ sel: Selector) -> IMP? {
        guard let client, client.responds(to: sel),
              let method = class_getInstanceMethod(type(of: client), sel) else { return nil }
        return method_getImplementation(method)
    }

    /// 无参、返回 BOOL 的私有方法（initializeHID 之类）
    private func callBoolNoArg(_ sel: Selector) -> Bool {
        guard let client, let imp = implementation(sel) else { return false }
        return unsafeBitCast(imp, to: BoolNoArg.self)(client, sel)
    }

    private func scheduleClient() {
        guard let client, let imp = implementation(Sel.schedule) else { return }
        unsafeBitCast(imp, to: VoidQueue.self)(client, Sel.schedule, DispatchQueue.main)
    }

    private func registerStateCallback() {
        guard let client, let imp = implementation(Sel.stateCallback) else { return }
        let fn = unsafeBitCast(imp, to: BoolBlock.self)
        let ok = fn(client, Sel.stateCallback) { [weak self] value in
            guard let self else { return }
            self.stateLock.lock()
            self.panelState = value
            self.stateLock.unlock()
        }
        if !ok { Log.write("常亮：面板亮灭回调注册失败，只靠档位轮询") }
    }

    private func readDisplayID() -> UInt32 {
        guard let client, let imp = implementation(Sel.displayID) else { return 0 }
        return unsafeBitCast(imp, to: UInt32NoArg.self)(client, Sel.displayID)
    }

    private func readDimmingStep() -> Int64 {
        guard let client, let imp = implementation(Sel.dimmingStep) else { return 0 }
        return unsafeBitCast(imp, to: Int64NoArg.self)(client, Sel.dimmingStep)
    }

    @discardableResult
    private func setStep(_ step: Int64) -> Bool {
        guard let client, let imp = implementation(Sel.dimToStep) else { return false }
        return unsafeBitCast(imp, to: BoolInt64.self)(client, Sel.dimToStep, step)
    }

    @discardableResult
    private func turnOnPanel() -> Bool {
        guard let client, let imp = implementation(Sel.turnOn) else { return false }
        return unsafeBitCast(imp, to: BoolNoArg.self)(client, Sel.turnOn)
    }

    // MARK: - 只读诊断（命令行 / 面板用）

    /// 拿句柄、读档位和状态，**什么都不改**。返回可直接打印的键值对。
    func diagnose() -> [(String, String)] {
        var rows: [(String, String)] = []
        let ok = loadFramework()
        rows.append(("framework", ok ? "已加载" : "加载失败"))

        guard ok, let obj = makeClient() else {
            rows.append(("client", "创建失败"))
            return rows
        }
        // 真在跑的话 client 被占着，诊断完要还回去
        let previous = client
        client = obj
        defer { client = previous }

        let id = readDisplayID()
        rows.append(("displayID", id == UInt32.max ? "\(id)（无效，系统没给句柄）" : "\(id)"))
        rows.append(("dimmingStep", "\(readDimmingStep())  （0 = 原亮度，≥2 就是暗了）"))
        rows.append(("panelState", "\(currentPanelState)  （1 = 灭 / 2 = 亮）"))
        rows.append(("displayAwake", displayIsAwake ? "是" : "否（主屏睡着）"))
        rows.append(("screenLocked", isScreenLocked ? "是" : "否"))
        rows.append(("accessibility", AXIsProcessTrusted() ? "已授权（可走模拟输入）" : "未授权（模拟输入不可用）"))
        return rows
    }

    /// 真的按一次 0 档并回报前后档位 —— 命令行 `backlight --try` 用，验证这条路通不通
    func tryUndim() -> String {
        guard loadFramework(), let obj = makeClient() else { return "客户端创建失败" }
        let previous = client
        client = obj
        defer { client = previous }
        scheduleClient()

        let before = readDimmingStep()
        let ok = setStep(0)
        usleep(400_000)
        let after = readDimmingStep()
        return "调用前档位 \(before) → dimToStep(0) 返回 \(ok ? "成功" : "被拒") → 400ms 后档位 \(after)"
    }
}
