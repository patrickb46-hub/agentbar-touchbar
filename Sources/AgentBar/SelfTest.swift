import Foundation

/// 状态机自检：用合成日志把「每种尾部形状」跑一遍，断言不会误报「已完成」。
///
/// 这些用例全部来自真实日志的实测间隔（见 WorkBuddyAdapter.Timing 注释），
/// 以后改判定逻辑先 `make test`，别凭感觉调阈值。
enum SelfTest {

    private struct Row {
        var type: String
        var role: String?
        var name: String?
        var callId: String?
        var offset: Double      // 相对 T0 的秒数
    }

    private static var failures = 0
    private static var checks = 0

    static func run() -> Int32 {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 固定基准时间，避免依赖真实时钟
        let base = Date(timeIntervalSince1970: 1_795_000_000)

        func fixture(_ name: String, _ rows: [Row]) -> URL {
            let t0 = base.timeIntervalSince1970 * 1000
            let lines = rows.map { row -> String in
                var obj: [String: Any] = [
                    "type": row.type,
                    "timestamp": Int64(t0 + row.offset * 1000),
                    "sessionId": "selftest-\(name)",
                    "cwd": "/tmp/agentbar-selftest"
                ]
                if let role = row.role { obj["role"] = role }
                if let name = row.name { obj["name"] = name }
                if let callId = row.callId { obj["callId"] = callId }
                return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }
            let url = dir.appendingPathComponent("\(name).jsonl")
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let adapter = WorkBuddyAdapter(root: dir)

        /// expect: nil 表示应判为空闲（卡片消失）
        func check(_ title: String, file: URL, at offset: Double, expect: Phase?) {
            checks += 1
            let now = base.addingTimeInterval(offset)
            let actual = adapter.snapshot(file, at: now)?.phase
            let ok = actual == expect
            if !ok { failures += 1 }
            let want = expect.map { $0.rawValue } ?? "idle(不显示)"
            let got = actual.map { $0.rawValue } ?? "idle(不显示)"
            print("\(ok ? "  ok  " : "  FAIL") \(title)：期望 \(want)，实际 \(got)")
        }

        print("WorkBuddy 状态机自检")

        // 1. 新回合刚开始：user 消息之后，首条条目要 3.6～12.7 秒才落盘。
        //    旧逻辑在这里会因为「存在上一轮的 assistant 消息」直接判完成。
        let start = fixture("start", [
            Row(type: "message", role: "user", offset: 0)
        ])
        check("新回合 user 后 3s", file: start, at: 3, expect: .thinking)
        check("新回合 user 后 12s", file: start, at: 12, expect: .thinking)

        // 2. 工具结果之后模型重新开口：中位 4.8 秒、p90 15.7 秒。这段必须是「思考中」。
        let gap = fixture("toolgap", [
            Row(type: "message", role: "user", offset: 0),
            Row(type: "reasoning", offset: 1),
            Row(type: "function_call", name: "Bash", callId: "c1", offset: 1.2),
            Row(type: "function_call_result", name: "Bash", callId: "c1", offset: 2.0)
        ])
        check("工具结果后 1s", file: gap, at: 3, expect: .thinking)
        check("工具结果后 5s（中位间隔）", file: gap, at: 7, expect: .thinking)
        check("工具结果后 16s（p90 间隔）", file: gap, at: 18, expect: .thinking)

        // 3. 工具正在跑：只有 call，没有 result
        let running = fixture("running", [
            Row(type: "message", role: "user", offset: 0),
            Row(type: "function_call", name: "Bash", callId: "c9", offset: 1)
        ])
        check("工具执行中 10s", file: running, at: 11, expect: .tool)
        check("工具卡住 40 分钟", file: running, at: 2400, expect: nil)

        // 4. 中途叙述：assistant 消息后 0.1～0.3 秒就跟上工具调用 → 立刻转「执行中」
        let narration = fixture("narration", [
            Row(type: "message", role: "user", offset: 0),
            Row(type: "message", role: "assistant", offset: 5),
            Row(type: "function_call", name: "Read", callId: "c2", offset: 5.2)
        ])
        check("中途叙述接上工具调用", file: narration, at: 6, expect: .tool)

        // 5. 真完成：assistant 收尾 + 记账条目晚到
        let done = fixture("done", [
            Row(type: "message", role: "user", offset: 0),
            Row(type: "function_call", name: "Bash", callId: "c3", offset: 1),
            Row(type: "function_call_result", name: "Bash", callId: "c3", offset: 2),
            Row(type: "reasoning", offset: 6),
            Row(type: "message", role: "assistant", offset: 7)
        ])
        check("收尾消息后 0.5s（还在确认）", file: done, at: 7.5, expect: .thinking)
        check("收尾消息后 3s", file: done, at: 10, expect: .done)
        check("收尾消息后 100s（保留期内）", file: done, at: 107, expect: .done)
        check("收尾消息后 200s（已过期）", file: done, at: 207, expect: nil)

        // 6. 记账条目（credit-usage / file-history-snapshot / session-meta）不应推迟完成
        let bookkeeping = fixture("bookkeeping", [
            Row(type: "message", role: "user", offset: 0),
            Row(type: "message", role: "assistant", offset: 5),
            Row(type: "credit-usage", offset: 5.3),
            Row(type: "file-history-snapshot", offset: 6),
            Row(type: "session-meta", offset: 9)
        ])
        check("记账条目拖到 9s 后仍判完成", file: bookkeeping, at: 9, expect: .done)

        // 7. 只有记账条目、没有实质内容 → 不显示
        let empty = fixture("bookkeepingonly", [
            Row(type: "session-meta", offset: 0),
            Row(type: "ai-title", offset: 1)
        ])
        check("只有记账条目", file: empty, at: 2, expect: nil)

        // 8. 长时间没动静：卡片消失，而不是永远挂着
        check("user 后静默 11 分钟", file: start, at: 670, expect: nil)

        print(failures == 0
              ? "全部通过（\(checks) 项）"
              : "\(failures)/\(checks) 项失败")
        return failures == 0 ? 0 : 1
    }

    // MARK: - 真实日志回归

    /// 拿最近真实会话做回放：在每条「有状态含义」的条目之后 2 秒采样一次，
    /// 凡是判成「已完成」的，检查后面 30 秒内是否还有工具调用 / 思考 —— 有就是误报。
    static func runReal() -> Int32 {
        let root = Paths.home.appendingPathComponent(".workbuddy/projects", isDirectory: true)
        var files: [URL] = []
        for dir in FileUtil.subdirs(in: root) {
            for f in FileUtil.files(in: dir, matching: "jsonl") {
                if Date().timeIntervalSince(FileUtil.mtime(f)) < 6 * 3600 { files.append(f) }
            }
        }
        files.sort { FileUtil.mtime($0) > FileUtil.mtime($1) }
        files = Array(files.prefix(6))
        guard !files.isEmpty else {
            print("真实日志回归：最近 6 小时没有会话，跳过")
            return 0
        }

        let signalTypes: Set<String> = ["message", "reasoning", "function_call", "function_call_result"]
        let adapter = WorkBuddyAdapter(root: root)
        var samples = 0, falseDone = 0

        print("真实日志回归（\(files.count) 个会话）")
        for file in files {
            let rows = JSONLTail.allObjects(file)
            let signals = rows.enumerated().filter { signalTypes.contains($0.element["type"] as? String ?? "") }
            for (idx, row) in signals.suffix(80) {
                guard let ts = (row["timestamp"] as? NSNumber)?.doubleValue else { continue }
                let now = Date(timeIntervalSince1970: ts / 1000 + 2.0)
                samples += 1
                guard let snap = adapter.snapshot(file, at: now), snap.phase == .done else { continue }
                // 判成完成了：看后面 30 秒内还有没有「同一回合的继续动作」。
                // 只看工具调用 / 思考 / 工具结果：assistant 消息本身就是收尾，
                // 用户紧接着发新消息也属于另一轮，都不算误报。
                let follow = rows[(idx + 1)...].prefix { r in
                    ((r["timestamp"] as? NSNumber)?.doubleValue ?? 0) <= ts + 30_000
                }
                let continueTypes: Set<String> = ["function_call", "reasoning", "function_call_result"]
                let busy = follow.contains { continueTypes.contains($0["type"] as? String ?? "") }
                if busy {
                    falseDone += 1
                    if falseDone <= 5 {
                        let nxt = follow.first?["type"] as? String ?? "?"
                        print("  FAIL 误报完成：\(file.lastPathComponent.prefix(8)) t=\(Int(ts / 1000)) 之后紧跟 \(nxt)")
                    }
                }
            }
        }

        checks += samples
        failures += falseDone
        let rate = samples > 0 ? Double(falseDone) / Double(samples) * 100 : 0
        print(String(format: "采样 %d 次，误报完成 %d 次（%.2f%%）", samples, falseDone, rate))
        return falseDone == 0 ? 0 : 1
    }
}
