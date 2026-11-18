import Foundation

/// GitHub Copilot CLI 适配器
///
/// 数据源：`~/.copilot/session-state/<sessionId>/events.jsonl`
/// 事件：session.start / user.message / system.message / assistant.turn_start /
///       assistant.message（带 toolRequests）/ assistant.turn_end /
///       session.shutdown / session.error / abort
struct CopilotAdapter {
    let root = Paths.home.appendingPathComponent(".copilot/session-state", isDirectory: true)

    func scan(now: Date = Date()) -> [AgentSnapshot] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let maxAge: TimeInterval = AgentBarConfig.ignoreAge ? 1e9 : 2 * 3600
        var out: [AgentSnapshot] = []
        for dir in FileUtil.subdirs(in: root) {
            let file = dir.appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let age = now.timeIntervalSince(FileUtil.mtime(file))
            if age > maxAge { continue }
            if let snap = parse(file: file, sessionId: dir.lastPathComponent, age: age) {
                out.append(snap)
            }
        }
        return out
    }

    func debugParse(_ file: URL) -> AgentSnapshot? {
        parse(file: file, sessionId: file.deletingLastPathComponent().lastPathComponent, age: 0, force: true)
    }

    func parse(file: URL, sessionId: String, age: TimeInterval, force: Bool = false) -> AgentSnapshot? {
        let objs = JSONLTail.objects(file)
        guard !objs.isEmpty else { return nil }

        var lastType = ""
        var lastMs: Double = 0
        var userMs: Double?
        var turnStartMs: Double?
        var cwd: String?
        var tool: String?

        for obj in objs {
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

        var phase: Phase
        switch lastType {
        case "assistant.turn_end", "session.shutdown":
            phase = age < 60 ? .done : .idle
        case "session.error", "abort":
            phase = age < 120 ? .error : .idle
        case "session.start":
            phase = age < 60 ? .thinking : .idle
        default:
            phase = tool != nil ? .tool : .thinking
        }
        if phase == .idle, !force { return nil }

        return AgentSnapshot(
            provider: "copilot-cli",
            sessionId: sessionId,
            project: cwd.map { ($0 as NSString).lastPathComponent } ?? "copilot",
            cwd: cwd,
            phase: phase,
            tool: tool,
            note: nil,
            turnStartedAt: Int64(turnStartMs ?? userMs ?? lastMs),
            updatedAt: Int64(lastMs > 0 ? lastMs : Date().timeIntervalSince1970 * 1000),
            jumpUrl: nil
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

    func scan(now: Date = Date()) -> [AgentSnapshot] {
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return [] }
        let maxAge: TimeInterval = AgentBarConfig.ignoreAge ? 1e9 : 3 * 3600
        var out: [AgentSnapshot] = []
        for file in FileUtil.files(in: cacheDir, matching: "json") {
            let age = now.timeIntervalSince(FileUtil.mtime(file))
            if age > maxAge { continue }
            if let snap = parse(file: file, now: now) { out.append(snap) }
        }
        return out
    }

    func debugParse(_ file: URL) -> AgentSnapshot? {
        parse(file: file, now: Date(), force: true)
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

        let approval = (rows["approvalState"] as? [String: Any])?["val"] as? [String: Any]
        let turnOpen = (approval?["turnOpen"] as? Bool) ?? false
        let policy = approval?["policy"] as? String

        var phase: Phase
        if turnOpen, policy == "ask" {
            phase = .waitingApproval
        } else if openSeq != nil {
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
        let project = (cwd.map { ($0 as NSString).lastPathComponent }) ?? title ?? "dsh"

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
            jumpUrl: nil
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
