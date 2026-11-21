import AppKit
import SwiftUI

/// `agentbar panel --out xxx.png`：把控制面板离屏渲染成图片。
/// 用来做文档截图，也方便改完布局自查一眼（不用真去点菜单栏）。
final class PanelPreviewActions: PanelActions {
    func panelSetEnabled(_ on: Bool) {}
    func panelRemount() {}
    func panelCalibrate() {}
    func panelRestoreHidden() {}
    func panelExportPreview() {}
    func panelOpenStateDir() {}
    func panelOpenLog() {}
    func panelQuit() {}
    func panelAutostart(_ on: Bool) -> Bool { on }
    func panelIsAutostart() -> Bool { false }
    func panelRefreshNow() {}
    func panelSetKeepLit(_ on: Bool) -> String { on ? "生效中 · 还没需要干预" : "未开启" }
    func panelOpenAccessibilitySettings() {}
}

enum PanelCLI {
    static func render(_ args: [String]) {
        _ = NSApplication.shared

        var kv: [String: String] = [:]
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("--") {
                let key = String(args[i].dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { kv[key] = args[i + 1]; i += 2 }
                else { kv[key] = "true"; i += 1 }
            } else { i += 1 }
        }

        let out = kv["out"] ?? (NSHomeDirectory() + "/Desktop/agentbar-panel.png")
        let width = CGFloat(Double(kv["width"] ?? "") ?? Double(PanelMetrics.width))
        let height = CGFloat(Double(kv["height"] ?? "") ?? Double(PanelMetrics.height))

        let center = ControlCenter(actions: PanelPreviewActions())
        // 预览图里常亮是开着的，状态文字给个真实的样子（不然显示成「—」）
        center.keepLit = true
        center.keepLitStatus = ProcessInfo.processInfo.environment["PANEL_PREVIEW_NEED_PERM"] == "1" ? "需要「辅助功能」权限才能保活" : "生效中 · 还没需要干预"
        center.keepLitNeedsPermission = ProcessInfo.processInfo.environment["PANEL_PREVIEW_NEED_PERM"] == "1"
        if kv["live"] != nil {
            Store.shared.syncToday()
            let model = Store.shared.model()
            center.model = model
            center.statusLine = model.primary.map { "\($0.phase.label) · \($0.displayName)" } ?? "暂无 AI 活动"
            center.detailLine = model.primary.map { providerShort($0.provider) } ?? ""
            center.cpu = "-"
        } else {
            let now = nowMs()
            let live = AgentSnapshot(provider: "workbuddy-desktop", sessionId: "demo",
                                     project: "Genius Touch Bar", title: "让 Touch Bar 始终保持常亮",
                                     cwd: nil, phase: .thinking,
                                     tool: nil, note: nil, turnStartedAt: now - 96_000,
                                     updatedAt: now, jumpUrl: nil)
            let other = AgentSnapshot(provider: "copilot-cli", sessionId: "demo2",
                                      project: "Stock Market Sim", title: "修复回测脚本的时区问题",
                                      cwd: nil, phase: .waitingApproval,
                                      tool: nil, note: nil, turnStartedAt: now - 42_000,
                                      updatedAt: now, jumpUrl: nil)
            center.model = BarModel(primary: live, others: [other],
                                    today: TodayStats(turns: 12, seconds: 6420, tokens: 38_200), tick: 3)
            center.statusLine = "思考中 · 让 Touch Bar 始终保持常亮"
            center.detailLine = "WorkBuddy · 另外 1 个会话"
            center.cpu = "0.4%"
        }
        center.refreshFromConfig()

        let hosting = NSHostingView(rootView: PanelView(center: center))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        if kv["fit"] != nil {
            let fit = hosting.fittingSize
            print(String(format: "自然尺寸：%.0f x %.0f", fit.width, fit.height))
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("渲染失败：拿不到位图")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败：PNG 编码失败")
            return
        }
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url)
        print("已渲染面板：\(out)")
    }
}
