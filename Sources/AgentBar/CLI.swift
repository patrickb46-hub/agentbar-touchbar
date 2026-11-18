import AppKit
import Foundation

enum CLI {

    static let helpText = """
    agentbar — 把 AI 的工作状态放到 MacBook Touch Bar 上

    用法：
      agentbar                         启动菜单栏 App 并接管 Touch Bar
      agentbar report --provider p ... 上报一条状态（任何工具都能调）
      agentbar hook                    从 stdin 读 hook JSON（Claude Code / Codex / WorkBuddy 格式）
      agentbar render [--out 路径]      把当前界面渲染成 PNG（不需要 Touch Bar 硬件）
      agentbar dump                    以 JSON 打印当前识别到的所有 agent
      agentbar clean                   清掉 ~/.agentbar/state 里的上报文件

    report 参数：
      --provider 名称     必填，例如 mytool
      --session  ID       默认 default
      --state 状态        thinking | tool | waiting_approval | done | error | idle
      --tool 工具名       例如 Bash
      --cwd 目录          默认当前目录
      --project 名称      默认取 cwd 最后一段
      --since 毫秒时间戳   本轮开始时间，默认现在
      --jump URL          点击 Touch Bar 时打开的链接
    """
    static let reportHelp = "用法：agentbar report --provider 名称 --state thinking [--session ID] [--tool Bash] [--cwd 目录] [--jump URL]"

    // MARK: - report

    static func report(_ args: [String]) {
        var kv: [String: String] = [:]
        var i = 0
        while i < args.count {
            let token = args[i]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    kv[key] = args[i + 1]; i += 2
                } else {
                    kv[key] = "true"; i += 1
                }
            } else { i += 1 }
        }

        guard let provider = kv["provider"], !provider.isEmpty else {
            FileHandle.standardError.write((reportHelp + "\n").data(using: .utf8)!)
            exit(2)
        }

        let cwd = kv["cwd"] ?? FileManager.default.currentDirectoryPath
        let session = kv["session"] ?? "default"
        let project = kv["project"] ?? (cwd as NSString).lastPathComponent

        var obj: [String: Any] = [
            "schema": 1,
            "provider": provider,
            "sessionId": session,
            "cwd": cwd,
            "project": project,
            "state": kv["state"] ?? "thinking",
            "updatedAt": nowMs(),
            "turnStartedAt": Int64(kv["since"] ?? "") ?? nowMs(),
            "source": "report"
        ]
        if let tool = kv["tool"] { obj["tool"] = tool }
        if let jump = kv["jump"] { obj["jumpUrl"] = jump }
        if let note = kv["note"] { obj["note"] = note }

        writeState(obj, provider: provider, session: session)
    }

    // MARK: - hook（stdin）

    static func hook() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            exit(0)   // 永远不要因为解析失败卡住主流程
        }

        let event = (obj["hook_event_name"] as? String)
            ?? (obj["hookEventName"] as? String)
            ?? (obj["event"] as? String)
            ?? ""
        let toolName = (obj["tool_name"] as? String) ?? (obj["toolName"] as? String)
        let session = (obj["session_id"] as? String)
            ?? (obj["sessionId"] as? String)
            ?? "hook"
        let cwd = (obj["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
        let provider = ProcessInfo.processInfo.environment["AGENTBAR_PROVIDER"] ?? "hook"

        let state: String
        switch event.lowercased() {
        case "pretooluse":            state = "tool"
        case "posttooluse":           state = "thinking"
        case "userpromptsubmit":      state = "thinking"
        case "notification":          state = "waiting_approval"
        case "stop", "sessionend":    state = "done"
        case "subagentstop":          state = "thinking"
        default:                      state = "thinking"
        }

        var out: [String: Any] = [
            "schema": 1,
            "provider": provider,
            "sessionId": session,
            "cwd": cwd,
            "project": (cwd as NSString).lastPathComponent,
            "state": state,
            "updatedAt": nowMs(),
            "turnStartedAt": nowMs(),
            "source": "hook"
        ]
        if let toolName, !toolName.isEmpty { out["tool"] = toolName }
        writeState(out, provider: provider, session: session)
        exit(0)
    }

    // MARK: - dump

    static func dump() {
        Store.shared.syncToday()
        let model = Store.shared.model()
        var rows: [[String: Any]] = []
        if let p = model.primary { rows.append(describe(p)) }
        for o in model.others { rows.append(describe(o)) }
        let payload: [String: Any] = [
            "primary": rows.first ?? [:],
            "all": rows,
            "today": ["turns": model.today.turns,
                      "seconds": Int(model.today.seconds),
                      "tokens": model.today.tokens ?? 0]
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
    }

    private static func describe(_ s: AgentSnapshot) -> [String: Any] {
        var d: [String: Any] = [
            "provider": s.provider,
            "session": s.sessionId,
            "project": s.project,
            "phase": s.phase.rawValue,
            "updatedAt": s.updatedAt
        ]
        if let tool = s.tool { d["tool"] = tool }
        if let e = s.elapsed { d["elapsed"] = Int(e) }
        if let j = s.jumpUrl { d["jump"] = j }
        return d
    }

    // MARK: - clean

    static func clean() {
        Paths.ensure()
        let files = FileUtil.files(in: Paths.stateDir, matching: "json")
        for f in files { try? FileManager.default.removeItem(at: f) }
        print("已清理 \(files.count) 个上报文件")
    }

    // MARK: - render（无硬件预览）

    static func render(_ args: [String]) {
        _ = NSApplication.shared

        var kv: [String: String] = [:]
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("--") {
                let key = String(args[i].dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    kv[key] = args[i + 1]; i += 2
                } else { kv[key] = "true"; i += 1 }
            } else { i += 1 }
        }

        let out = kv["out"] ?? (NSHomeDirectory() + "/Desktop/agentbar-preview.png")
        let width = CGFloat(Double(kv["width"] ?? "") ?? 1000)

        var model: BarModel
        if kv["multi"] != nil {
            let now = nowMs()
            func demo(_ provider: String, _ project: String, _ phase: Phase,
                      _ elapsed: Double, _ tool: String?) -> AgentSnapshot {
                AgentSnapshot(provider: provider, sessionId: project, project: project, cwd: nil,
                              phase: phase, tool: tool, note: nil,
                              turnStartedAt: now - Int64(elapsed * 1000), updatedAt: now,
                              jumpUrl: nil)
            }
            let agents = [
                demo("workbuddy-desktop", "Genius Touch Bar", .tool, 143, "Bash"),
                demo("copilot-cli", "Stock Market Sim", .waitingApproval, 62, nil),
                demo("dsh", "DSH Plugins", .thinking, 27, nil)
            ]
            model = BarModel(primary: agents[0], others: Array(agents.dropFirst()),
                             today: TodayStats(turns: 12, seconds: 6420, credits: 4.2), tick: 3)
        } else if kv["idle"] != nil || kv["live"] == nil {
            let today = TodayStats(turns: 12, seconds: 6420, tokens: 38_200)
            model = BarModel(primary: nil, others: [], today: today, tick: 3)
        } else {
            let phase = Phase(rawValue: kv["state"] ?? "thinking") ?? .thinking
            let elapsed = Double(kv["elapsed"] ?? "") ?? 83
            let now = nowMs()
            let snap = AgentSnapshot(
                provider: "workbuddy-desktop",
                sessionId: "demo",
                project: kv["project"] ?? "Genius Touch Bar",
                cwd: nil,
                phase: phase,
                tool: kv["tool"] ?? "Bash",
                note: kv["note"],
                turnStartedAt: now - Int64(elapsed * 1000),
                updatedAt: now,
                jumpUrl: "workbuddy://chat/demo"
            )
            model = BarModel(primary: snap, others: [],
                             today: TodayStats(turns: 12, seconds: 6420, credits: 4.2), tick: 3)
        }

        writePNG(model: model, to: out, width: width)
        print("已渲染：\(out)")
    }

    // MARK: - 落盘与出图

    static func writeState(_ obj: [String: Any], provider: String, session: String) {
        Paths.ensure()
        let safe = "\(provider)-\(session)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let url = Paths.stateDir.appendingPathComponent(safe + ".json")
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func writePNG(model: BarModel, to path: String,
                         width: CGFloat = 1000, height: CGFloat = BarStyle.height, scale: CGFloat = 2) {
        let pxW = Int(width * scale), pxH = Int(height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        BarRenderer.draw(model, in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}

extension CLI {
    /// 调试：直接解析某个 provider 的最新几个会话，忽略「空闲/太旧」过滤
    static func probe(_ args: [String]) {
        var kv: [String: String] = [:]
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("--") {
                let key = String(args[i].dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { kv[key] = args[i + 1]; i += 2 }
                else { kv[key] = "true"; i += 1 }
            } else { i += 1 }
        }

        let provider = kv["provider"] ?? "copilot"

        if let single = kv["file"] {
            let url = URL(fileURLWithPath: (single as NSString).expandingTildeInPath)
            let snap = provider == "dsh" ? DSHAdapter().debugParse(url) : CopilotAdapter().debugParse(url)
            guard let s = snap else { print("解析失败"); return }
            let tool = s.tool.map { " tool=\($0)" } ?? ""
            print("\(s.phase.rawValue)  \(providerShort(s.provider)) · \(s.project)\(tool)  cwd=\(s.cwd ?? "-")")
            return
        }
        var files: [URL] = []
        switch provider {
        case "copilot":
            let root = Paths.home.appendingPathComponent(".copilot/session-state", isDirectory: true)
            files = FileUtil.subdirs(in: root)
                .map { $0.appendingPathComponent("events.jsonl") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        case "dsh":
            let dir = Paths.home.appendingPathComponent(".dsh/storages/session_projcache/sessions", isDirectory: true)
            files = FileUtil.files(in: dir, matching: "json")
        default:
            print("未知 provider：\(provider)（可选 copilot / dsh）")
            return
        }

        files.sort { FileUtil.mtime($0) > FileUtil.mtime($1) }
        let limit = Int(kv["limit"] ?? "5") ?? 5
        let copilot = CopilotAdapter()
        let dsh = DSHAdapter()

        for file in files.prefix(limit) {
            let snap = provider == "copilot" ? copilot.debugParse(file) : dsh.debugParse(file)
            let stamp = ISODate.short(FileUtil.mtime(file))
            if let s = snap {
                let tool = s.tool.map { " tool=\($0)" } ?? ""
                print("[\(stamp)] \(s.phase.rawValue)  \(providerShort(s.provider)) · \(s.project)\(tool)  cwd=\(s.cwd ?? "-")")
            } else {
                print("[\(stamp)] 解析失败或空")
            }
        }
    }
}

extension ISODate {
    static func short(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}
