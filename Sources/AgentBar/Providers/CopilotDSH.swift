import Foundation

/// GitHub Copilot CLI 适配器
///
/// 数据源：`~/.copilot/session-state/<sessionId>/events.jsonl`
/// 事件：session.start / user.message / system.message / assistant.turn_start /
///       assistant.message（带 toolRequests）/ assistant.turn_end /
///       session.shutdown / session.error / abort
final class CopilotAdapter {
    let root = Paths.home.appendingPathComponent(".copilot/session-state", isDirectory: true)
    /// 进程内计时，避开不同时钟源
    private var turnClock: [String: (key: Int64, at: TimeInterval)] = [:]

    /// 每个会话的增量状态（只解析追加的行）
    private struct Session {
        var stamp: FileStamp
        var state: Parsed
        var follower: TailFollower
    }
    private var sessions: [String: Session] = [:]

    func scan(now: Date = Date()) -> [AgentSnapshot] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let maxAge: TimeInterval = AgentBarConfig.ignoreAge ? 1e9 : 2 * 3600
        var out: [AgentSnapshot] = []
        var alive = Set<String>()

        for dir in DirLister.shared.subdirs(in: root) {
            let file = dir.appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let stamp = FileStamp.read(file)
            let age = now.timeIntervalSince(stamp.mtime > 0 ? Date(timeIntervalSince1970: stamp.mtime) : .distantPast)
            if age > maxAge { continue }

            let sid = dir.lastPathComponent
            alive.insert(sid)

            var session = sessions[sid]
            if session == nil || stamp.size < (session?.stamp.size ?? 0) {
                let follower = TailFollower()
                follower.reset(to: stamp.size)
                session = Session(stamp: stamp, state: Parsed.parsing(JSONLTail.objects(file)), follower: follower)
            } else if let old = session, stamp.size != old.stamp.size {
                let (lines, truncated) = old.follower.read(url: file, size: stamp.size)
                if truncated {
                    let follower = TailFollower()
                    follower.reset(to: stamp.size)
                    session = Session(stamp: stamp, state: Parsed.parsing(JSONLTail.objects(file)), follower: follower)
                } else {
                    var state = old.state
                    for line in lines {
                        if let obj = JSONLTail.parseLine(line) { state.ingest(obj) }
                    }
                    session = Session(stamp: stamp, state: state, follower: old.follower)
                }
            }
            guard let current = session else { continue }
            sessions[sid] = current
            if let snap = snapshot(from: current.state, sessionId: sid, age: age) {
                out.append(snap)
            }
        }

        if sessions.count > alive.count { sessions = sessions.filter { alive.contains($0.key) } }
        return out
    }

    func debugParse(_ file: URL) -> AgentSnapshot? {
        let state = Parsed.parsing(JSONLTail.objects(file))
        return snapshot(from: state, sessionId: file.deletingLastPathComponent().lastPathComponent, age: 0, force: true)
    }

    /// 事件流折叠出来的会话状态
    private struct Parsed {
        var lastType = ""
        var lastMs: Double = 0
        var userMs: Double?
        var turnStartMs: Double?
        var cwd: String?
        var tool: String?

        static func parsing(_ objs: [[String: Any]]) -> Parsed {
            var p = Parsed()
            p.merge(objs)
            return p
        }

        mutating func merge(_ objs: [[String: Any]]) {
            for obj in objs { ingest(obj) }
        }

        mutating func ingest(_ obj: [String: Any]) {
            let type = (obj["type"] as? String) ?? ""
            let data = obj["data"] as? [String: Any]
            let ms = (obj["timestamp"] as? String).flatMap { ISODate.ms($0) } ?? 0
            if ms > lastMs { lastMs = ms }
            lastType = type

            switch type {
            case "session.start":
                if let ctx = data?["context"] as? [String: Any] {
                    cwd = ctx["cwd"] as? String
                }
                if userMs == nil { userMs = ms }
            case "user.message":
                userMs = ms
            case "assistant.turn_start":
                turnStartMs = ms
                tool = nil
            case "assistant.message":
                if let requests = data?["toolRequests"] as? [[String: Any]], let first = requests.first {
                    tool = (first["name"] as? String) ?? "tool"
                } else {
                    tool = nil
                }
            case "assistant.turn_end":
                turnStartMs = nil
                tool = nil
            default:
                break
            }
        }
    }

    func parse(file: URL, sessionId: String, age: TimeInterval, force: Bool = false) -> AgentSnapshot? {
        snapshot(from: Parsed.parsing(JSONLTail.objects(file)), sessionId: sessionId, age: age, force: force)
    }

    private func snapshot(from state: Parsed, sessionId: String, age: TimeInterval,
                          force: Bool = false) -> AgentSnapshot? {
        var phase: Phase
        switch state.lastType {
        case "assistant.turn_end", "session.shutdown":
            phase = age < 60 ? .done : .idle
        case "session.error", "abort":
            phase = age < 120 ? .error : .idle
        case "session.start":
            phase = age < 60 ? .thinking : .idle
        default:
            phase = state.tool != nil ? .tool : .thinking
        }
        if phase == .idle, !force { return nil }

        let turnKey = Int64(state.turnStartMs ?? state.userMs ?? 0)
        var startedAt: Int64?
        if phase != .done {
            if let cached = turnClock[sessionId], cached.key == turnKey {
                startedAt = Int64(cached.at * 1000)
            } else {
                turnClock[sessionId] = (turnKey, Date().timeIntervalSince1970)
                startedAt = Int64(Date().timeIntervalSince1970 * 1000)
            }
        } else {
            turnClock[sessionId] = nil
        }

        var durationMs: Int64?
        if phase == .done, let u = state.userMs, let t = state.turnStartMs, t >= u {
            durationMs = Int64(t - u)
        }

        return AgentSnapshot(
            provider: "copilot-cli",
            sessionId: sessionId,
            project: state.cwd.map { ($0 as NSString).lastPathComponent } ?? "copilot",
            cwd: state.cwd,
            phase: phase,
            tool: state.tool,
            note: nil,
            turnStartedAt: startedAt,
            updatedAt: Int64(state.lastMs > 0 ? state.lastMs : Date().timeIntervalSince1970 * 1000),
            jumpUrl: nil,
            durationMs: durationMs
        )
    }
}

/// dsh（DeepSeek Harness）适配器
///
/// 数据源：`~/.dsh/storages/session_projcache/sessions/session-<uuid>.json`
/// 关键字段：
///   record.identity.cwd / createdAt
///   record.rows.turnBoundary.val  = { openTurnStartSeq, lastStepBoundary.kind, lastTurn }
///   record.rows.approvalState.val = { policy, turnOpen }
///   record.rows.title.val         = 会话标题
///   record.rows.tokenUsage.val    = { totals: { uncachedInputTokens, outputTokens, ... } }
final class DSHAdapter {
    private let cacheDir = Paths.home.appendingPathComponent(".dsh/storages/session_projcache/sessions", isDirectory: true)

    /// 记录每轮第一次被看到的时间，用来算耗时（缓存文件本身不含时间戳）
    private var turnStartCache: [String: (seq: Int, at: Double)] = [:]

    /// 整份 JSON 快照缓存：文件没变就不再读
    private var snapshots: [String: (stamp: FileStamp, snap: AgentSnapshot?)] = [:]
    /// 今日用量缓存
    private var usageCache: [String: (stamp: FileStamp, tokens: Int, cost: Double)] = [:]

    func scan(now: Date = Date()) -> [AgentSnapshot] {
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return [] }
        let maxAge: TimeInterval = AgentBarConfig.ignoreAge ? 1e9 : 3 * 3600
        var out: [AgentSnapshot] = []
        var alive = Set<String>()

        for item in DirLister.shared.files(in: cacheDir, ext: "json") {
            let age = now.timeIntervalSince(Date(timeIntervalSince1970: item.stamp.mtime))
            if age > maxAge { continue }
            let path = item.url.path
            alive.insert(path)

            if let cached = snapshots[path], cached.stamp == item.stamp {
                if let snap = cached.snap { out.append(snap) }
                continue
            }
            let snap = parse(file: item.url, now: now)
            snapshots[path] = (item.stamp, snap)
            if let snap { out.append(snap) }
        }

        if snapshots.count > alive.count { snapshots = snapshots.filter { alive.contains($0.key) } }
        return out
    }

    func debugParse(_ file: URL) -> AgentSnapshot? {
        parse(file: file, now: Date(), force: true)
    }

    /// 今天用掉多少 token、按官方价格折合多少钱（估算）
    func todayUsage() -> (tokens: Int, cost: Double) {
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return (0, 0) }
        var tokens = 0
        var cost = 0.0
        let cal = Calendar.current
        var alive = Set<String>()

        for item in DirLister.shared.files(in: cacheDir, ext: "json", ttl: 10, verify: false) {
            guard cal.isDateInToday(Date(timeIntervalSince1970: item.stamp.mtime)) else { continue }
            let path = item.url.path
            alive.insert(path)
            let entry: (tokens: Int, cost: Double)
            if let cached = usageCache[path], cached.stamp == item.stamp {
                entry = (cached.tokens, cached.cost)
            } else {
                entry = Self.usage(file: item.url, stamp: item.stamp)
                usageCache[path] = (item.stamp, entry.tokens, entry.cost)
            }
            tokens += entry.tokens
            cost += entry.cost
        }

        if usageCache.count > alive.count { usageCache = usageCache.filter { alive.contains($0.key) } }
        return (tokens, cost)
    }

    private static func usage(file: URL, stamp: FileStamp) -> (Int, Double) {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any],
              let rows = record["rows"] as? [String: Any] else { return (0, 0) }

        let usage = (rows["tokenUsage"] as? [String: Any])?["val"] as? [String: Any]
        let totals = usage?["totals"] as? [String: Any]
        let cacheRead = (totals?["cacheReadTokens"] as? NSNumber)?.intValue ?? 0
        let uncached = (totals?["uncachedInputTokens"] as? NSNumber)?.intValue ?? 0
        let output = (totals?["outputTokens"] as? NSNumber)?.intValue ?? 0
        guard cacheRead + uncached + output > 0 else { return (0, 0) }

        let model = ((rows["modelSelection"] as? [String: Any])?["val"] as? [String: Any])
            .flatMap { ($0["lastUsed"] as? [String: Any])?["model"] as? String } ?? "deepseek-flash"

        let cost = Pricing.cost(cacheReadTokens: cacheRead, uncachedInputTokens: uncached,
                                outputTokens: output, model: model,
                                at: Date(timeIntervalSince1970: stamp.mtime))
        return (cacheRead + uncached + output, cost)
    }

    func parse(file: URL, now: Date, force: Bool = false) -> AgentSnapshot? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any],
              let rows = record["rows"] as? [String: Any] else { return nil }

        let identity = record["identity"] as? [String: Any]
        let cwd = identity?["cwd"] as? String
        let uuid = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "session-", with: "")

        let boundary = (rows["turnBoundary"] as? [String: Any])?["val"] as? [String: Any]
        let openSeq = (boundary?["openTurnStartSeq"] as? NSNumber)?.intValue
        let stepBoundary = boundary?["lastStepBoundary"] as? [String: Any]
        let stepKind = stepBoundary?["kind"] as? String

        // 注意：approvalState.turnOpen 表示「本轮是否允许弹审批」，不是「正在等你」，
        // 用它判待确认会一直误报。dsh 目前只区分 执行 / 思考 / 空。
        var phase: Phase
        if openSeq != nil {
            phase = stepKind == "start" ? .tool : .thinking
        } else {
            phase = .idle
        }
        if phase == .idle, !force { return nil }

        // 计时：缓存里没有时间戳，用第一次观察到这一轮的墙钟时间
        var startedAt: Int64?
        if let seq = openSeq {
            if let cached = turnStartCache[uuid], cached.seq == seq {
                startedAt = Int64(cached.at * 1000)
            } else {
                let nowMsD = now.timeIntervalSince1970 * 1000
                turnStartCache[uuid] = (seq, now.timeIntervalSince1970)
                startedAt = Int64(nowMsD)
            }
        } else {
            turnStartCache[uuid] = nil
        }

        let title = (rows["title"] as? [String: Any])?["val"] as? String
        // 优先用会话标题（一眼知道在干什么），没有才退回目录名
        let project = title?.isEmpty == false ? title! :
            ((cwd.map { ($0 as NSString).lastPathComponent }) ?? "dsh")

        // 本会话累计用量与金额（只读 tokenUsage，不碰 permissions）
        var sessionTokens: Int?
        var sessionCost: Double?
        if let usage = (rows["tokenUsage"] as? [String: Any])?["val"] as? [String: Any],
           let totals = usage["totals"] as? [String: Any] {
            let cacheRead = (totals["cacheReadTokens"] as? NSNumber)?.intValue ?? 0
            let uncached = (totals["uncachedInputTokens"] as? NSNumber)?.intValue ?? 0
            let output = (totals["outputTokens"] as? NSNumber)?.intValue ?? 0
            if cacheRead + uncached + output > 0 {
                sessionTokens = cacheRead + uncached + output
                let model = ((rows["modelSelection"] as? [String: Any])?["val"] as? [String: Any])
                    .flatMap { ($0["lastUsed"] as? [String: Any])?["model"] as? String } ?? "deepseek-flash"
                sessionCost = Pricing.cost(cacheReadTokens: cacheRead, uncachedInputTokens: uncached,
                                           outputTokens: output, model: model,
                                           at: FileUtil.mtime(file))
            }
        }

        return AgentSnapshot(
            provider: "dsh",
            sessionId: uuid,
            project: project,
            cwd: cwd,
            phase: phase,
            tool: nil,
            note: nil,
            turnStartedAt: startedAt,
            updatedAt: Int64(FileUtil.mtime(file).timeIntervalSince1970 * 1000),
            jumpUrl: nil,
            tokens: sessionTokens,
            costCNY: sessionCost,
            jumpApp: "DeepSeek Harness"
        )
    }
}

// MARK: - ISO8601 解析

enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func ms(_ s: String) -> Double? {
        if let d = withFraction.date(from: s) ?? plain.date(from: s) {
            return d.timeIntervalSince1970 * 1000
        }
        return nil
    }
}

extension ISODate {
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
