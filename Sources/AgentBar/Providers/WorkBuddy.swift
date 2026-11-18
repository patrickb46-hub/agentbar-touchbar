import Foundation

/// WorkBuddy 桌面版 / CodeBuddy CLI 共用适配器。
///
/// 数据源：`~/.workbuddy/projects/<项目slug>/<sessionId>.jsonl`
/// 每行一个条目，关键字段：
///   type = message | reasoning | function_call | function_call_result | credit-usage
///   timestamp（毫秒）、sessionId、cwd、role（仅 message）
///
/// 状态推导（已用真实数据验证）：
///   message(role=user)     → 新回合开始
///   reasoning              → 思考中
///   function_call 无 result → 正在跑该工具
///   message(role=assistant)→ 回合结束
struct WorkBuddyAdapter {
    let provider: String
    let root: URL

    /// 只有最近改动过的文件才值得每秒解析
    private static var candidates: [URL] = []
    private static var candidateStamp: TimeInterval = 0

    init(provider: String = "workbuddy-desktop",
         root: URL = Paths.home.appendingPathComponent(".workbuddy/projects", isDirectory: true)) {
        self.provider = provider
        self.root = root
    }

    func available() -> Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    private func refreshCandidates(now: Date) {
        if now.timeIntervalSince1970 - Self.candidateStamp < 8, !Self.candidates.isEmpty { return }
        Self.candidateStamp = now.timeIntervalSince1970

        var found: [URL] = []
        let cutoff = now.addingTimeInterval(-12 * 3600)
        for projectDir in FileUtil.subdirs(in: root) {
            for file in FileUtil.files(in: projectDir, matching: "jsonl") {
                if FileUtil.mtime(file) > cutoff { found.append(file) }
            }
        }
        Self.candidates = found
    }

    func scan(now: Date = Date()) -> [AgentSnapshot] {
        guard available() else { return [] }
        refreshCandidates(now: now)

        var out: [AgentSnapshot] = []
        for file in Self.candidates {
            let age = now.timeIntervalSince(FileUtil.mtime(file))
            if age > 3 * 3600 { continue }
            if let snap = parse(file: file, now: now) { out.append(snap) }
        }
        return out
    }

    // MARK: - 单文件解析

    private struct Parsed {
        var sessionId = ""
        var cwd: String?
        var lastUserMs: Double?
        var lastAssistantMs: Double?
        var lastEntryMs: Double = 0
        var lastKind = ""
        var pending: [String: (tool: String, ts: Double, args: String)] = [:]
    }

    /// 一眼就知道要跑很久的命令，别把它误判成「等你确认」
    private static let longRunningMarkers = [
        "build", "install", "npm ", "pip ", "brew ", "cargo ", "make ", "swift ",
        "test", "ffmpeg", "yt-dlp", "git clone", "curl ", "wget ", "download", "rsync"
    ]

    private func parse(file: URL, now: Date) -> AgentSnapshot? {
        let objs = JSONLTail.objects(file, maxBytes: 2 * 1024 * 1024)
        guard !objs.isEmpty else { return nil }

        var p = Parsed()
        for obj in objs {
            let ts = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
            if let sid = obj["sessionId"] as? String, !sid.isEmpty { p.sessionId = sid }
            if let cwd = obj["cwd"] as? String, !cwd.isEmpty { p.cwd = cwd }
            if ts > p.lastEntryMs { p.lastEntryMs = ts }

            switch obj["type"] as? String {
            case "message":
                switch obj["role"] as? String {
                case "user": p.lastUserMs = ts; p.pending.removeAll(); p.lastKind = "user"
                case "assistant": p.lastAssistantMs = ts; p.lastKind = "assistant"
                default: break
                }
            case "reasoning":
                p.lastKind = "reasoning"
            case "function_call":
                let callId = (obj["callId"] as? String) ?? UUID().uuidString
                let name = (obj["name"] as? String) ?? "tool"
                var args = ""
                if let s = obj["arguments"] as? String {
                    args = s
                } else if let d = obj["arguments"], JSONSerialization.isValidJSONObject(d),
                          let data = try? JSONSerialization.data(withJSONObject: d) {
                    args = String(data: data, encoding: .utf8) ?? ""
                }
                p.pending[callId] = (name, ts, args)
                p.lastKind = "function_call"
            case "function_call_result":
                if let callId = obj["callId"] as? String { p.pending.removeValue(forKey: callId) }
                p.lastKind = "function_call_result"
            case "session-meta":
                if p.cwd == nil, let meta = obj["meta"] as? [String: Any] {
                    p.cwd = meta["cwd"] as? String
                }
            default:
                break
            }
        }

        guard p.lastEntryMs > 0 else { return nil }
        let nowMsD = now.timeIntervalSince1970 * 1000
        let quietMs = nowMsD - p.lastEntryMs
        if quietMs > 3 * 3600 * 1000 { return nil }

        // 长会话的 user 消息可能落在尾部窗口之外，单独回扫一次
        if p.lastUserMs == nil {
            p.lastUserMs = JSONLTail.lastUserTimestamp(file)
        }

        // 当前挂起的工具调用（取最近一次）
        let pendingTool = p.pending.max { $0.value.ts < $1.value.ts }

        var phase: Phase
        var tool: String?
        var note: String?

        if let pending = pendingTool {
            tool = pending.value.tool
            let argsLower = pending.value.args.lowercased()
            let looksLong = Self.longRunningMarkers.contains { argsLower.contains($0) }
            let threshold: Double = looksLong ? 120_000 : 4_000
            if quietMs > threshold {
                phase = .waitingApproval
                note = looksLong ? "疑似" : nil
            } else {
                phase = .tool
            }
        } else if p.lastKind == "reasoning" || p.lastKind == "user" {
            phase = quietMs < 120_000 ? .thinking : .idle
        } else if let assistant = p.lastAssistantMs, (nowMsD - assistant) < 90_000 {
            phase = .done
        } else {
            phase = .idle
        }

        if phase == .idle { return nil }

        let sessionId = p.sessionId.isEmpty
            ? file.deletingPathExtension().lastPathComponent
            : p.sessionId
        let project = (p.cwd.map { ($0 as NSString).lastPathComponent }) ?? file.deletingLastPathComponent().lastPathComponent
        let jump = "workbuddy://chat/" + (sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId)

        return AgentSnapshot(
            provider: provider,
            sessionId: sessionId,
            project: project.isEmpty ? provider : project,
            cwd: p.cwd,
            phase: phase,
            tool: tool,
            note: note,
            turnStartedAt: p.lastUserMs.map { Int64($0) },
            updatedAt: Int64(p.lastEntryMs),
            jumpUrl: jump
        )
    }

    // MARK: - 今日累计

    func todayStats(now: Date = Date()) -> TodayStats {
        guard available() else { return TodayStats() }
        let cal = Calendar.current
        var stats = TodayStats()
        var tokens = 0
        var credits = 0.0

        for projectDir in FileUtil.subdirs(in: root) {
            for file in FileUtil.files(in: projectDir, matching: "jsonl") {
                guard cal.isDateInToday(FileUtil.mtime(file)) else { continue }
                var turnStart: Double?
                for obj in JSONLTail.allObjects(file) {
                    let ts = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
                    switch obj["type"] as? String {
                    case "message":
                        if (obj["role"] as? String) == "user" {
                            stats.turns += 1
                            turnStart = ts
                        } else if (obj["role"] as? String) == "assistant", let start = turnStart {
                            stats.seconds += max(0, (ts - start) / 1000)
                            turnStart = nil
                        }
                    case "credit-usage":
                        if let pd = obj["providerData"] as? [String: Any] {
                            credits += (pd["credit"] as? NSNumber)?.doubleValue ?? 0
                            tokens += TokenHarvest.harvest(pd)
                        }
                    default: break
                    }
                }
            }
        }

        stats.tokens = tokens > 0 ? tokens : nil
        stats.credits = credits
        return stats
    }
}
