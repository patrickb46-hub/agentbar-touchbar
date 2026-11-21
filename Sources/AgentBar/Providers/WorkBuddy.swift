import Foundation

/// WorkBuddy 桌面版 / CodeBuddy CLI 共用适配器。
///
/// 数据源：`~/.workbuddy/projects/<项目slug>/<sessionId>.jsonl`
/// 每行一个条目，关键字段：
///   type = message | reasoning | function_call | function_call_result | credit-usage
///   timestamp（毫秒）、sessionId、cwd、role（仅 message）
///
/// 状态推导（事件驱动 + 「尾部形状」，不靠静默时长猜）：
///   message(role=user)               → 回合打开 → 思考中
///   reasoning / function_call_result → 思考中（模型在准备下一步）
///   function_call 无 result           → 正在跑该工具
///   message(role=assistant) 且是末条  → 停顿一小会儿后 → 完成
///   「等你确认」不看时长，看 ~/.workbuddy/audit-log 里的 ask-matched / needs-approval
///
/// 卡片名（会话名，不是工作区目录名）：
///   `ai-title` 条目（会话开头写一次）→ `session-meta` 里顺带的那份（每个回合都有，
///   长会话也能从尾部读到）→ `workbuddy.db` 的 sessions 表（见 SessionTitles）。
///   三样都没有才退回 `cwd` 最后一段。
///
/// 关键教训（2026-11-19 回归）：**只有 assistant 消息落在尾部才可能是完成**。
/// 实测数据：工具结果之后模型重新开口的中位间隔 4.8 秒（p90 15.7 秒），
/// 新回合 user 消息之后首条条目要 3.6～12.7 秒。
/// 旧逻辑「安静 2 秒 + 存在任意 assistant 消息 = 完成」会把这两段空窗全判成已完成，
/// 表现为每调一次工具闪一次「已完成」、新回合开头还停在上一轮的「已完成」。
///
/// 性能（2026-11-19）：每个文件维护一份增量状态，只有追加了字节才解析新增那几行；
/// 文件没变就直接用上次的解析结果 + 当前时间重算阶段。819 个会话文件也不会拖慢刷新。
final class WorkBuddyAdapter {
    let provider: String
    let root: URL

    /// 只有最近改动过的文件才值得每个周期 stat 一次
    private var candidates: [(url: URL, stamp: FileStamp)] = []
    private var candidateStamp: TimeInterval = 0

    /// 用进程自己的时钟记「第一次看到这一轮」的时刻，
    /// 避免日志时间戳与系统时钟不同源导致耗时算成几小时。
    private var turnClock: [String: (key: Int64, at: TimeInterval)] = [:]

    /// 每个文件一份增量状态
    private struct FileState {
        var stamp: FileStamp
        var parsed: Parsed
        var follower: TailFollower
        /// 已经为这个文件回扫过「最后一条 user 消息」，别每轮再扫 16 MB
        var userScanned: Bool
    }
    private var states: [String: FileState] = [:]

    init(provider: String = "workbuddy-desktop",
         root: URL = Paths.home.appendingPathComponent(".workbuddy/projects", isDirectory: true)) {
        self.provider = provider
        self.root = root
    }

    func available() -> Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    private func refreshCandidates(now: Date) {
        if now.timeIntervalSince1970 - candidateStamp < 8, !candidates.isEmpty { return }
        candidateStamp = now.timeIntervalSince1970

        var found: [(URL, FileStamp)] = []
        let cutoff = now.timeIntervalSince1970 - 12 * 3600
        for projectDir in DirLister.shared.subdirs(in: root) {
            for item in DirLister.shared.files(in: projectDir, ext: "jsonl") where item.stamp.mtime > cutoff {
                found.append(item)
            }
        }
        candidates = found.map { (url: $0.0, stamp: $0.1) }

        // 掉队的文件状态清掉，别让字典长成天文数字
        let alive = Set(candidates.map { $0.url.path })
        states = states.filter { alive.contains($0.key) }
    }

    func scan(now: Date = Date()) -> [AgentSnapshot] {
        guard available() else { return [] }
        refreshCandidates(now: now)

        var out: [AgentSnapshot] = []
        out.reserveCapacity(candidates.count)
        for item in candidates {
            let age = now.timeIntervalSince1970 - item.stamp.mtime
            if age > 3 * 3600 { continue }
            if let snap = snapshot(file: item.url, stamp: item.stamp, now: now) { out.append(snap) }
        }
        return out
    }

    // MARK: - 单文件解析

    /// 自检用：用指定的「现在」解析某个日志文件，不走候选文件过滤
    func snapshot(_ file: URL, at now: Date) -> AgentSnapshot? {
        var parsed = Parsed.parsing(JSONLTail.objects(file, maxBytes: 2 * 1024 * 1024))
        if parsed.lastUserMs == nil { parsed.lastUserMs = JSONLTail.lastUserTimestamp(file) }
        return snapshot(from: parsed, file: file, now: now)
    }

    /// 带缓存/增量的一条：文件没变就不碰磁盘
    private func snapshot(file: URL, stamp: FileStamp, now: Date) -> AgentSnapshot? {
        let path = file.path
        var state = states[path]
        var needFullParse = state == nil || stamp.size < (state?.stamp.size ?? 0)

        if !needFullParse, let old = state, stamp.size != old.stamp.size {
            let (lines, truncated) = old.follower.read(url: file, size: stamp.size)
            if truncated {
                needFullParse = true
            } else {
                var parsed = old.parsed
                for line in lines {
                    if let obj = JSONLTail.parseLine(line) { parsed.ingest(obj) }
                }
                state = FileState(stamp: stamp, parsed: parsed, follower: old.follower,
                                  userScanned: old.userScanned)
            }
        }

        if needFullParse {
            let objs = JSONLTail.objects(file, maxBytes: 2 * 1024 * 1024)
            guard !objs.isEmpty else {
                states.removeValue(forKey: path)
                return nil
            }
            let follower = TailFollower()
            follower.reset(to: stamp.size)
            state = FileState(stamp: stamp, parsed: Parsed.parsing(objs),
                              follower: follower, userScanned: false)
        }

        guard var current = state else { return nil }
        current.stamp = stamp

        // 长会话的 user 消息可能落在尾部窗口之外，单独回扫一次（每个文件只扫一次）
        if current.parsed.lastUserMs == nil, !current.userScanned {
            current.userScanned = true
            current.parsed.lastUserMs = JSONLTail.lastUserTimestamp(file)
        }
        states[path] = current

        return snapshot(from: current.parsed, file: file, now: now)
    }

    /// 尾部形状：最后一条「有状态含义」的条目是什么。记账类条目不算。
    private enum Tail {
        case user, assistant, reasoning, toolCall, toolResult, none
    }

    private struct Parsed {
        var sessionId = ""
        var cwd: String?
        /// 会话名：从 `ai-title` 条目或 `session-meta` 里带出来的标题。
        /// 只做「有则更新」，因为会话名可能在应用里被改名。
        var title: String?
        var lastUserMs: Double?
        var lastAssistantMs: Double?
        /// 任何条目的最新时间戳（含记账类），只用来判「这个会话还新不新」
        var lastEntryMs: Double = 0
        /// 最后一条有状态含义的条目的时间戳，静默时长从这里算
        var lastSignalMs: Double = 0
        var tail: Tail = .none
        var pending: [String: (tool: String, ts: Double)] = [:]

        static func parsing(_ objs: [[String: Any]]) -> Parsed {
            var p = Parsed()
            p.merge(objs)
            return p
        }

        mutating func merge(_ objs: [[String: Any]]) {
            for obj in objs { ingest(obj) }
        }

        mutating func ingest(_ obj: [String: Any]) {
            let ts = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
            if let sid = obj["sessionId"] as? String, !sid.isEmpty { sessionId = sid }
            if let dir = obj["cwd"] as? String, !dir.isEmpty { cwd = dir }
            if ts > lastEntryMs { lastEntryMs = ts }

            switch obj["type"] as? String {
            case "message":
                switch obj["role"] as? String {
                case "user":
                    lastUserMs = ts
                    pending.removeAll()
                    tail = .user
                case "assistant":
                    lastAssistantMs = ts
                    tail = .assistant
                default:
                    return        // 其它角色不改变尾部形状
                }
                lastSignalMs = max(lastSignalMs, ts)
            case "reasoning":
                tail = .reasoning
                lastSignalMs = max(lastSignalMs, ts)
            case "function_call":
                if let callId = obj["callId"] as? String {
                    pending[callId] = ((obj["name"] as? String) ?? "tool", ts)
                }
                tail = .toolCall
                lastSignalMs = max(lastSignalMs, ts)
            case "function_call_result":
                if let callId = obj["callId"] as? String { pending.removeValue(forKey: callId) }
                tail = .toolResult
                lastSignalMs = max(lastSignalMs, ts)
            case "session-meta":
                if cwd == nil, let meta = obj["meta"] as? [String: Any] {
                    cwd = meta["cwd"] as? String
                }
                // session-meta 会把当前会话标题顺带记一份
                // （meta["codebuddy.ai/sessionTitle"] = [{type: ai-title, aiTitle: ...}]），
                // 长会话的 ai-title 条目在文件开头读不到，靠这个补上
                if let meta = obj["meta"] as? [String: Any],
                   let carried = WorkBuddyAdapter.sessionTitle(in: meta), !carried.isEmpty {
                    title = carried
                }
            case "ai-title":
                if let name = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    title = name
                }
            // credit-usage / file-history-snapshot / model-usage 等是记账条目，
            // 会在回合结束后几秒内才落盘，不能拿它们推进「静默计时」，否则完成态会被推迟。
            default:
                break
            }
        }
    }

    /// session-meta 里带的会话标题：值形如 `[{type: ai-title, aiTitle: "..."}]`。
    /// 键名带命名空间（`codebuddy.ai/sessionTitle`），认「含 sessiontitle」而不是写死。
    private static func sessionTitle(in meta: [String: Any]) -> String? {
        for (key, value) in meta {
            guard key.lowercased().contains("sessiontitle"),
                  let list = value as? [[String: Any]] else { continue }
            for item in list.reversed() {
                if let name = (item["aiTitle"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    return name
                }
            }
        }
        return nil
    }

    /// 判定用的时间常数（秒）。改之前先看注释里的实测值。
    enum Timing {
        /// assistant 消息之后等这么久再确认完成。中途叙述到工具调用实测 p99 = 0.3 秒，
        /// 1.5 秒足够，也不会让「真完成」等太久。
        static let settleAfterAssistant: Double = 1.5
        /// 完成态在 Touch Bar 上留多久
        static let doneLinger: Double = 120
        /// 尾部是「思考 / 工具结果 / 用户消息」时，静默多久算走神（模型长思考实测最长 ~9.6 分钟）
        static let quietIdle: Double = 600
        /// 只有调用没有结果的工具（会话被 kill），超过这么久就不再当「执行中」
        static let staleToolCall: Double = 1800
    }

    private func snapshot(from p: Parsed, file: URL, now: Date) -> AgentSnapshot? {
        guard p.lastEntryMs > 0, p.lastSignalMs > 0 else { return nil }
        let nowMsD = now.timeIntervalSince1970 * 1000
        if nowMsD - p.lastEntryMs > 3 * 3600 * 1000 { return nil }

        let sessionId = p.sessionId.isEmpty
            ? file.deletingPathExtension().lastPathComponent
            : p.sessionId

        // 只有调用没有结果的工具，久了就不再算「正在跑」
        let stillFresh = p.pending.filter { (nowMsD - $0.value.ts) / 1000 < Timing.staleToolCall }
        let quiet = (nowMsD - p.lastSignalMs) / 1000

        // 到底有没有在等你，以应用自己的审计日志为准
        let audit = AuditLog.waitingApproval(sessionId: sessionId)
        let pendingTool = stillFresh.max { $0.value.ts < $1.value.ts }

        var phase: Phase
        var tool: String?
        if audit.isWaiting {
            phase = .waitingApproval
            tool = pendingTool?.value.tool
        } else if let pending = pendingTool {
            phase = .tool
            tool = pending.value.tool
        } else {
            switch p.tail {
            case .assistant:
                // 唯一可能是「走完了」的尾部形状，还要等一小会儿确认不是中途叙述
                if quiet < Timing.settleAfterAssistant { phase = .thinking }
                else if quiet < Timing.doneLinger { phase = .done }
                else { phase = .idle }
            case .toolCall:
                phase = quiet < Timing.quietIdle ? .tool : .idle
            case .user, .reasoning, .toolResult:
                phase = quiet < Timing.quietIdle ? .thinking : .idle
            case .none:
                phase = .idle
            }
        }

        if phase == .idle { return nil }

        // 本轮起点：用进程时钟记第一次观察时间
        let turnKey = Int64(p.lastUserMs ?? 0)
        var startedAt: Int64?
        if phase != .done {
            if let cached = turnClock[sessionId], cached.key == turnKey {
                startedAt = Int64(cached.at * 1000)
            } else {
                turnClock[sessionId] = (turnKey, now.timeIntervalSince1970)
                startedAt = Int64(now.timeIntervalSince1970 * 1000)
            }
        } else {
            turnClock[sessionId] = nil
        }

        // 本轮耗时：两端都取日志里的时间戳，天然同源
        var durationMs: Int64?
        if phase == .done, let user = p.lastUserMs, let done = p.lastAssistantMs, done >= user {
            durationMs = Int64(done - user)
        }

        let project = (p.cwd.map { ($0 as NSString).lastPathComponent })
            ?? file.deletingLastPathComponent().lastPathComponent
        // 卡片显示会话名，不再显示工作区目录名：用户改过的名 > 日志里的 ai-title > 库里自动标题。
        // 三个都拿不到（极端情况）才退回目录名。
        let title = SessionTitles.shared.name(for: sessionId, logTitle: p.title)
        let jump = "workbuddy://chat/"
            + (sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId)

        return AgentSnapshot(
            provider: provider,
            sessionId: sessionId,
            project: project.isEmpty ? provider : project,
            title: title,
            cwd: p.cwd,
            phase: phase,
            tool: tool,
            note: audit.isWaiting ? audit.reason : nil,
            turnStartedAt: startedAt,
            updatedAt: Int64(p.lastEntryMs),
            jumpUrl: jump,
            durationMs: durationMs
        )
    }

    // MARK: - 今日累计

    /// 每个文件一次算好，之后文件没变就不再解析（原来 60 秒要把今天所有会话全文读一遍）
    private struct TodayTotals {
        var stamp: FileStamp
        var turns: Int
        var seconds: Double
        var tokens: Int
        var credits: Double
    }
    private var todayCache: [String: TodayTotals] = [:]

    func todayStats(now: Date = Date()) -> TodayStats {
        guard available() else { return TodayStats() }
        let cal = Calendar.current
        var stats = TodayStats()
        var tokens = 0
        var credits = 0.0
        var seen = Set<String>()

        for projectDir in DirLister.shared.subdirs(in: root) {
            for item in DirLister.shared.files(in: projectDir, ext: "jsonl", ttl: 10, verify: false) {
                guard cal.isDateInToday(Date(timeIntervalSince1970: item.stamp.mtime)) else { continue }
                let path = item.url.path
                seen.insert(path)

                var totals: TodayTotals
                if let cached = todayCache[path], cached.stamp == item.stamp {
                    totals = cached
                } else {
                    totals = Self.parseToday(item.url, stamp: item.stamp)
                    todayCache[path] = totals
                }
                stats.turns += totals.turns
                stats.seconds += totals.seconds
                tokens += totals.tokens
                credits += totals.credits
            }
        }

        // 过期的缓存条目清掉（跨天、文件被删）
        if todayCache.count > seen.count {
            todayCache = todayCache.filter { seen.contains($0.key) }
        }

        stats.tokens = tokens > 0 ? tokens : nil
        stats.credits = credits
        return stats
    }

    private static func parseToday(_ file: URL, stamp: FileStamp) -> TodayTotals {
        var totals = TodayTotals(stamp: stamp, turns: 0, seconds: 0, tokens: 0, credits: 0)
        var turnStart: Double?
        for obj in JSONLTail.allObjects(file) {
            let ts = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
            switch obj["type"] as? String {
            case "message":
                if (obj["role"] as? String) == "user" {
                    totals.turns += 1
                    turnStart = ts
                } else if (obj["role"] as? String) == "assistant", let start = turnStart {
                    totals.seconds += max(0, (ts - start) / 1000)
                    turnStart = nil
                }
            case "credit-usage":
                if let pd = obj["providerData"] as? [String: Any] {
                    totals.credits += (pd["credit"] as? NSNumber)?.doubleValue ?? 0
                    totals.tokens += TokenHarvest.harvest(pd)
                }
            default:
                break
            }
        }
        return totals
    }
}
