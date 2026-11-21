import Foundation

/// 登录自启：写一个 LaunchAgent plist，再让 launchd 认识它。
/// 和 Makefile 里的 `make autostart` 做的是同一件事，只是让面板能一键开关。
enum LaunchAgent {
    static let label = "com.string255.agentbar"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static var executablePath: String {
        Bundle.main.executableURL?.path
            ?? (NSHomeDirectory() + "/Applications/AgentBar.app/Contents/MacOS/agentbar")
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        Paths.ensure()
        if on {
            write()
            boot(["bootstrap", "gui/\(getuid())", plistURL.path])
        } else {
            boot(["bootout", "gui/\(getuid())", plistURL.path])
            try? FileManager.default.removeItem(at: plistURL)
        }
        let now = isEnabled
        Log.write(now == on ? "登录自启：\(on ? "已开启" : "已关闭")" : "登录自启设置失败（当前 \(now)）")
        return now
    }

    private static func write() {
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let errLog = Paths.root.appendingPathComponent("launchd.err.log").path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(executablePath)</string></array>
          <key>RunAtLoad</key><true/>
          <key>StandardErrorPath</key><string>\(errLog)</string>
        </dict></plist>
        """
        try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    private static func boot(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            Log.write("launchctl \(args.first ?? "") 失败：\(error.localizedDescription)")
        }
    }
}
