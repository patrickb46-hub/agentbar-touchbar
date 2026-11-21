import Foundation
import AppKit

// MARK: - 阶段

enum Phase: String {
    case thinking
    case tool
    case waitingApproval = "waiting_approval"
    case done
    case idle
    case error

    var label: String {
        switch self {
        case .thinking: return "思考中"
        case .tool: return "执行中"
        case .waitingApproval: return "待确认"
        case .done: return "已完成"
        case .idle: return "空闲"
        case .error: return "出错"
        }
    }

    var tint: NSColor {
        switch self {
        case .thinking: return NSColor(srgbRed: 0.29, green: 0.62, blue: 1.00, alpha: 1)
        case .tool:     return NSColor(srgbRed: 0.25, green: 0.71, blue: 0.91, alpha: 1)
        case .waitingApproval: return NSColor(srgbRed: 1.00, green: 0.76, blue: 0.29, alpha: 1)
        case .done:     return NSColor(srgbRed: 0.28, green: 0.85, blue: 0.51, alpha: 1)
        case .idle:     return NSColor(white: 0.42, alpha: 1)
        case .error:    return NSColor(srgbRed: 1.00, green: 0.40, blue: 0.38, alpha: 1)
        }
    }
}

// MARK: - 单个 agent 的快照

struct AgentSnapshot {
    var provider: String
    var sessionId: String
    /// 工作区目录名，只用来兜底和区分跳转目标，不再直接上屏
    var project: String
    /// 会话名：用户在应用里改过的名字 / ai-title / 库里自动标题
    var title: String? = nil
    var cwd: String?
    var phase: Phase
    var tool: String?
    var note: String?
    var turnStartedAt: Int64?   // ms
    var updatedAt: Int64        // ms
    var jumpUrl: String?
    /// 本轮真实耗时（来自日志自身的时间戳，跨时钟源也可靠）
    var durationMs: Int64? = nil
    /// 本会话累计 token / 估算金额
    var tokens: Int? = nil
    var costCNY: Double? = nil
    /// 该来源没有深链时，优先激活这个应用（而不是打开文件夹）
    var jumpApp: String? = nil

    /// 卡片上显示的名字：会话名优先。
    ///
    /// 同一工作区目录下可以开很多个会话（`2026-11-21-12-16-41` 这种目录名一模一样），
    /// 所以目录名只能当兜底 —— 拿不到会话名时才退回去。
    var displayName: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return project.isEmpty ? provider : project
    }

    /// 显示分组（数字小的排左边）：需要处理 > 进行中 > 已完成
    ///
    /// 只看「阶段」这一个维度，不看更新时间 —— 更新时刻每秒都在变，
    /// 拿它当排序依据，卡片就会一直左右换位置。
    /// 出错和待确认一样要人看一眼，所以同属「需要处理」。
    var displayGroup: Int {
        switch phase {
        case .waitingApproval, .error: return 0   // 需要处理
        case .thinking, .tool: return 1           // 进行中
        case .done: return 2                      // 已完成
        case .idle: return 3
        }
    }

    /// 组内的固定锚点：本轮开始时间；缺了才退回「第一次被看到的时间」。
    /// 用它排序，同一组里的卡片位置只在这轮换人开始时变一次，不会来回抖。
    func sortAnchor(firstSeen: Int64) -> Int64 {
        turnStartedAt ?? firstSeen
    }

    var isLive: Bool {
        switch phase {
        case .thinking, .tool, .waitingApproval, .error: return true
        case .done, .idle: return false
        }
    }

    var elapsed: TimeInterval? {
        guard isLive, let start = turnStartedAt else { return nil }
        return Self.sane(Double(nowMs()) - Double(start))
    }

    /// 系统时钟回拨 / 跳变时不要显示成 11 小时
    private static func sane(_ deltaMs: Double) -> TimeInterval {
        let seconds = deltaMs / 1000.0
        if seconds < 0 { return 0 }
        return min(seconds, 6 * 3600)
    }

    /// 已完成状态下这一轮实际花了多久
    var turnDuration: TimeInterval? {
        guard let ms = durationMs else { return nil }
        return Double(ms) / 1000.0
    }
}

/// 每个来源一个固定色，多进程并排时靠底色区分是哪个软件
func providerAccent(_ provider: String) -> NSColor {
    let p = provider.lowercased()
    if p.contains("workbuddy") || p.contains("codebuddy") {
        return NSColor(srgbRed: 0.29, green: 0.62, blue: 1.00, alpha: 1)   // 蓝
    }
    if p.contains("copilot") {
        return NSColor(srgbRed: 0.66, green: 0.51, blue: 1.00, alpha: 1)   // 紫
    }
    if p.contains("dsh") || p.contains("deepseek") {
        return NSColor(srgbRed: 0.24, green: 0.82, blue: 0.68, alpha: 1)   // 青绿
    }
    if p.contains("claude") {
        return NSColor(srgbRed: 0.95, green: 0.62, blue: 0.42, alpha: 1)   // 橙
    }
    if p.contains("codex") {
        return NSColor(srgbRed: 0.55, green: 0.80, blue: 0.45, alpha: 1)   // 草绿
    }
    // 未知来源：按名字散列到一组柔和的色相
    let palette: [(Double, Double, Double)] = [
        (0.95, 0.60, 0.65), (0.55, 0.75, 0.95), (0.85, 0.75, 0.45),
        (0.60, 0.85, 0.75), (0.80, 0.65, 0.95)
    ]
    var hash = 5381
    for byte in provider.utf8 { hash = (hash &* 33) &+ Int(byte) }
    let c = palette[abs(hash) % palette.count]
    return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - 今日统计

struct TodayStats {
    var turns: Int = 0
    var seconds: Double = 0
    var tokens: Int? = nil
    var credits: Double = 0
    var costCNY: Double = 0

    var isEmpty: Bool { turns == 0 && seconds < 1 }

    var durationText: String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    var costText: String? {
        guard costCNY > 0 else { return nil }
        if costCNY < 0.01 { return "<¥0.01" }
        return String(format: "¥%.2f", costCNY)
    }

    var tokensText: String? {
        guard let t = tokens, t > 0 else { return nil }
        if t >= 1_000_000 { return String(format: "%.1fM tok", Double(t) / 1_000_000) }
        if t >= 1000 { return String(format: "%.1fk tok", Double(t) / 1000) }
        return "\(t) tok"
    }
}

// MARK: - 时间格式

func clockText(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: - 上报/状态文件用的原始结构（宽松解码）

struct RawState {
    var provider: String = "unknown"
    var sessionId: String = ""
    var cwd: String?
    var project: String?
    /// 会话名（可选）：给了就显示它，不给退回 project / cwd
    var title: String?
    var state: String = "idle"
    var tool: String?
    var turnStartedAt: Int64?
    var updatedAt: Int64
    var jumpUrl: String?
    var note: String?

    var phase: Phase {
        switch state.lowercased() {
        case "thinking", "reasoning": return .thinking
        case "tool", "running", "working": return .tool
        case "waiting_approval", "approval", "waiting": return .waitingApproval
        case "done", "finished": return .done
        case "error", "failed": return .error
        default: return .idle
        }
    }

    init?(json: [String: Any]) {
        guard let provider = json["provider"] as? String, !provider.isEmpty else { return nil }
        self.provider = provider
        self.sessionId = (json["sessionId"] as? String) ?? (json["session_id"] as? String) ?? ""
        self.cwd = json["cwd"] as? String
        self.project = json["project"] as? String
        self.title = (json["title"] as? String) ?? (json["sessionTitle"] as? String)
        self.state = (json["state"] as? String) ?? "idle"
        self.tool = json["tool"] as? String
        self.turnStartedAt = (json["turnStartedAt"] as? NSNumber)?.int64Value
        self.updatedAt = (json["updatedAt"] as? NSNumber)?.int64Value ?? nowMs()
        self.jumpUrl = json["jumpUrl"] as? String
        self.note = json["note"] as? String
    }

    var snapshot: AgentSnapshot {
        let p = self.project ?? (cwd.map { $0 as NSString }).map { ($0.lastPathComponent) } ?? provider
        return AgentSnapshot(
            provider: provider,
            sessionId: sessionId,
            project: p.isEmpty ? provider : p,
            title: title,
            cwd: cwd,
            phase: phase,
            tool: tool,
            note: note,
            turnStartedAt: turnStartedAt,
            updatedAt: updatedAt,
            jumpUrl: jumpUrl
        )
    }
}

// MARK: - 状态目录

enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var root: URL { home.appendingPathComponent(".agentbar", isDirectory: true) }
    static var stateDir: URL { root.appendingPathComponent("state", isDirectory: true) }
    static var providersDir: URL { root.appendingPathComponent("providers", isDirectory: true) }

    static func ensure() {
        for dir in [root, stateDir, providersDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// 卡片上显示的软件短名
func providerShort(_ provider: String) -> String {
    let p = provider.lowercased()
    if p.contains("workbuddy") { return "WorkBuddy" }
    if p.contains("codebuddy") { return "CodeBuddy" }
    if p.contains("copilot") { return "Copilot" }
    if p.contains("dsh") || p.contains("deepseek") { return "dsh" }
    if p.contains("claude") { return "Claude" }
    if p.contains("codex") { return "Codex" }
    if p.contains("hook") { return "hook" }
    return provider
}
