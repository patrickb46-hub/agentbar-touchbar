import Foundation
import AppKit
import CoreGraphics

extension Notification.Name {
    /// 配置变了：重画、重新挂载、换刷新频率都听这个
    static let agentBarConfigChanged = Notification.Name("app.agentbar.configChanged")
}

/// 显示哪些元素。面板里的「显示结构」直接改这里。
struct Structure {
    var showDot = true
    var showElapsed = true
    var showProject = true
    var showTool = true
    var showSummary = true
    var showPet = true
    var maxCards = 4
}

enum AgentBarConfig {

    private static let configURL = Paths.root.appendingPathComponent("config.json")

    /// 扫描线程读、主线程写，统一用锁保护
    private static let lock = NSLock()
    private static var store: [String: Any] = load()
    /// 每次写盘 +1，渲染器用它判断「要不要重画」
    private(set) static var revision = 0

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: Paths.root.appendingPathComponent("config.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func read<T>(_ key: String, _ fallback: T) -> T {
        lock.lock(); defer { lock.unlock() }
        return (store[key] as? T) ?? fallback
    }

    private static func write(_ key: String, _ value: Any?) {
        lock.lock()
        if let value { store[key] = value } else { store.removeValue(forKey: key) }
        revision &+= 1
        let snapshot = store
        lock.unlock()
        persist(snapshot)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .agentBarConfigChanged, object: nil)
        }
    }

    private static func persist(_ snapshot: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        Paths.ensure()
        try? data.write(to: configURL)
    }

    // MARK: - 总开关

    /// 关掉 = 收起 Touch Bar、停止扫描（菜单栏图标留着）
    static var enabled: Bool {
        get { read("enabled", true) }
        set { write("enabled", newValue) }
    }

    // MARK: - 常亮

    /// 不让 Touch Bar 在闲置后变暗、熄灭。
    /// 系统默认行为是「60 秒没碰就调暗，再过十几秒全灭」，唤醒还得先点一下；
    /// 打开后 AgentBar 会把它按回去（见 Backlight.swift），代价是 OLED 老化快一点。
    static var keepLit: Bool {
        get { read("keepLit", true) }
        set { write("keepLit", newValue) }
    }

    // MARK: - 外观

    static var themeId: String { read("theme", "midnight") }
    static var accentHex: String? {
        lock.lock(); defer { lock.unlock() }
        return store["accent"] as? String
    }
    static var backgroundHex: String? {
        lock.lock(); defer { lock.unlock() }
        return store["background"] as? String
    }

    static func setTheme(_ id: String) { write("theme", id) }
    static func setAccent(_ hex: String?) { write("accent", hex) }
    static func setBackground(_ hex: String?) { write("background", hex) }

    /// 当前生效的主题：预设打底，自定义底色/强调色覆盖。
    /// 文字与叠加色按底色亮度整组换（深底配浅字、浅底配深字），
    /// 否则「浅色主题 + 深色底」会出现深字压在深底上。
    static var theme: Theme {
        let base = Themes.preset(themeId) ?? Themes.midnight
        let accent = accentHex.flatMap { NSColor(hex: $0) }
        let bg = backgroundHex.flatMap { NSColor(hex: $0) }
        guard accent != nil || bg != nil else { return base }

        var t = base
        if let bg {
            let light = bg.isLightBackground
            let palette = light ? Themes.paper : (base.isLight ? Themes.midnight : base)
            t.isLight = light
            t.background = bg
            t.primaryText = palette.primaryText
            t.secondaryText = palette.secondaryText
            t.faintText = palette.faintText
            t.surfaceFill = palette.surfaceFill
            t.surfaceStroke = palette.surfaceStroke
            t.strongFill = palette.strongFill
            t.strongStroke = palette.strongStroke
        }
        if let accent { t.accent = Themes.adapt(accent, light: t.isLight) }
        return t
    }

    // MARK: - 显示结构

    static var structure: Structure {
        lock.lock(); defer { lock.unlock() }
        var s = Structure()
        s.showDot = (store["showDot"] as? Bool) ?? s.showDot
        s.showElapsed = (store["showElapsed"] as? Bool) ?? s.showElapsed
        s.showProject = (store["showProject"] as? Bool) ?? s.showProject
        s.showTool = (store["showTool"] as? Bool) ?? s.showTool
        s.showSummary = (store["showSummary"] as? Bool) ?? s.showSummary
        s.showPet = (store["showPet"] as? Bool) ?? s.showPet
        s.maxCards = min(4, max(1, (store["maxCards"] as? NSNumber)?.intValue ?? s.maxCards))
        return s
    }

    static func setStructure(_ s: Structure) {
        lock.lock()
        store["showDot"] = s.showDot
        store["showElapsed"] = s.showElapsed
        store["showProject"] = s.showProject
        store["showTool"] = s.showTool
        store["showSummary"] = s.showSummary
        store["showPet"] = s.showPet
        store["maxCards"] = s.maxCards
        revision &+= 1
        let snapshot = store
        lock.unlock()
        persist(snapshot)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .agentBarConfigChanged, object: nil)
        }
    }

    // MARK: - 刷新频率

    /// 一个刷新周期的秒数。扫描已经改成增量，1 秒完全够用。
    static var refreshSeconds: Double {
        let v = read("refresh", 1.0 as Double)
        return min(5, max(0.5, v))
    }

    static func setRefresh(_ v: Double) { write("refresh", min(5, max(0.5, v))) }

    /// 菜单栏图标旁边要不要显示文字（状态 / 耗时）。
    /// 默认关：菜单栏挤的时候，带文字的宽条目最容易被系统整个藏掉。
    static var menuTitle: Bool {
        get { read("menuTitle", false) }
        set { write("menuTitle", newValue) }
    }

    /// 上次「首次启动自动弹面板」用的版本号
    static var lastPanelVersion: String {
        lock.lock(); defer { lock.unlock() }
        return (store["lastPanelVersion"] as? String) ?? ""
    }

    static func setLastPanelVersion(_ v: String) { write("lastPanelVersion", v) }

    // MARK: - Touch Bar 几何

    /// Touch Bar 应用区宽度（点）。启动后会从 _NSFunctionRowPanel 实测并自动纠正。
    static var barWidth: CGFloat {
        if let raw = ProcessInfo.processInfo.environment["AGENTBAR_WIDTH"], let v = Double(raw) {
            return CGFloat(v)
        }
        return 765
    }

    /// 右侧控制条（亮度/音量/Siri）占走的宽度。这一块在 panel 内部，
    /// 会盖住我们的画布，必须扣掉。可用「校准右侧边界」重新测量。
    static var reservedRight: CGFloat {
        if let raw = ProcessInfo.processInfo.environment["AGENTBAR_RESERVED_RIGHT"], let v = Double(raw) {
            return CGFloat(v)
        }
        lock.lock()
        let stored = (store["reservedRight"] as? NSNumber)?.doubleValue
        lock.unlock()
        return CGFloat(stored ?? 85)
    }

    static func setReservedRight(_ value: CGFloat) {
        write("reservedRight", Double(round(value)))
    }

    /// 标尺模式：画刻度，用来量出这台机器上应用区的真实宽度
    static var rulerMode: Bool {
        ProcessInfo.processInfo.environment["AGENTBAR_RULER"] == "1"
    }

    static var rulerWidth: CGFloat { 1200 }

    // MARK: - 单卡操作（长按菜单）

    static var focusKey: String? {
        lock.lock(); defer { lock.unlock() }
        return store["focus"] as? String
    }

    static func setFocus(_ key: String?) { write("focus", key) }

    /// key -> 到期时间（秒）。0 表示永久归档
    static var hiddenUntil: [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return (store["hidden"] as? [String: Double]) ?? [:]
    }

    static func hide(_ key: String, hours: Double) {
        var dict = hiddenUntil
        dict[key] = Date().timeIntervalSince1970 + hours * 3600
        write("hidden", dict)
        if focusKey == key { setFocus(nil) }
    }

    static func archive(_ key: String) {
        var dict = hiddenUntil
        dict[key] = 0
        write("hidden", dict)
        if focusKey == key { setFocus(nil) }
    }

    static func unhideAll() {
        write("hidden", nil)
    }

    static func isVisible(_ key: String, now: Date = Date()) -> Bool {
        guard let until = hiddenUntil[key] else { return true }
        if until == 0 { return false }                       // 已归档
        return now.timeIntervalSince1970 > until             // 过期自动恢复
    }

    /// 调试用：忽略「太旧就不显示」的过滤
    static var ignoreAge: Bool {
        ProcessInfo.processInfo.environment["AGENTBAR_IGNORE_AGE"] == "1"
    }
}
