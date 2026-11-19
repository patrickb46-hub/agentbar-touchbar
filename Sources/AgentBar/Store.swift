import Foundation
import AppKit

struct BarModel {
    var primary: AgentSnapshot?
    var others: [AgentSnapshot]
    var today: TodayStats
    var tick: Int

    var liveCount: Int {
        (primary?.isLive == true ? 1 : 0) + others.filter { $0.isLive }.count
    }
}

final class Store {
    static let shared = Store()

    static func key(_ s: AgentSnapshot) -> String { "\(s.provider)|\(s.sessionId)" }

    private let workbuddy = WorkBuddyAdapter()
    private let copilot = CopilotAdapter()
    private let dsh = DSHAdapter()

    private var cachedToday = TodayStats()
    private var todayStamp: TimeInterval = 0
    private var todayBusy = false
    var tick = 0

    func model() -> BarModel {
        var snaps = workbuddy.scan()
        snaps += copilot.scan()
        snaps += dsh.scan()
        snaps += externalStates()

        // 同一 provider+session 去重，取更新的那条
        var merged: [String: AgentSnapshot] = [:]
        for s in snaps {
            let key = Store.key(s)
            if let old = merged[key], old.updatedAt >= s.updatedAt { continue }
            merged[key] = s
        }

        // 长按菜单里隐藏 / 归档过的不再出现
        merged = merged.filter { AgentBarConfig.isVisible($0.key) }

        // 只看某一个
        if let focus = AgentBarConfig.focusKey, let only = merged[focus] {
            tick &+= 1
            return BarModel(primary: only, others: [], today: cachedToday, tick: tick)
        }

        let sorted = merged.values.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.updatedAt > b.updatedAt
        }

        tick &+= 1
        return BarModel(primary: sorted.first, others: Array(sorted.dropFirst().prefix(3)), today: cachedToday, tick: tick)
    }

    func refreshTodayIfNeeded() {
        let now = Date().timeIntervalSince1970
        if now - todayStamp < 60 || todayBusy { return }
        todayBusy = true
        todayStamp = now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var stats = self.workbuddy.todayStats()
            let dsh = self.dsh.todayUsage()
            if dsh.tokens > 0 { stats.tokens = dsh.tokens }
            stats.costCNY = dsh.cost
            DispatchQueue.main.async {
                self.cachedToday = stats
                self.todayBusy = false
            }
        }
    }

    /// 同步算一遍今日统计（CLI 调试用）
    func syncToday() {
        cachedToday = workbuddy.todayStats()
        todayStamp = Date().timeIntervalSince1970
    }

    // MARK: - 外部上报（~/.agentbar/state/*.json）

    private func externalStates() -> [AgentSnapshot] {
        let files = FileUtil.files(in: Paths.stateDir, matching: "json")
        let now = Date()
        var out: [AgentSnapshot] = []
        for file in files {
            let age = now.timeIntervalSince(FileUtil.mtime(file))
            if age > 600 { continue }        // 10 分钟没更新视为失效
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = RawState(json: obj) else { continue }
            if raw.phase == .idle { continue }
            out.append(raw.snapshot)
        }
        return out
    }
}
