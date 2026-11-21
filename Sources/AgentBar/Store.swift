import Foundation
import AppKit

struct BarModel {
    var primary: AgentSnapshot?
    var others: [AgentSnapshot]
    var today: TodayStats
    var tick: Int
    /// 是否处在「只看这个」的单卡聚焦状态（只有这时才给「← 全部」按钮）
    var focused: Bool = false

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

    /// 所有磁盘 IO 都排在这条串行队列上，主线程只拿结果
    private let queue = DispatchQueue(label: "app.agentbar.scan", qos: .utility)
    private let stateLock = NSLock()
    private var inFlight = false

    private var cachedToday = TodayStats()
    private var todayStamp: TimeInterval = 0
    private var tick = 0

    /// 上报状态文件（~/.agentbar/state）的解析缓存
    private var externalCache: [String: (stamp: FileStamp, snap: AgentSnapshot)] = [:]

    /// 每个会话第一次被看到的时刻（ms）。快照缺 turnStartedAt 时拿它当排序锚点，
    /// 保证排序结果不依赖「谁刚更新过」。
    private var firstSeen: [String: Int64] = [:]

    // MARK: - 异步刷新（主线程定时器调用）

    /// 合并请求：上一轮还没扫完就跳过，绝不堆积
    func refresh(completion: @escaping (BarModel) -> Void) {
        stateLock.lock()
        if inFlight { stateLock.unlock(); return }
        inFlight = true
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.refreshTodayIfNeeded()
            let model = self.model()
            DispatchQueue.main.async {
                self.stateLock.lock()
                self.inFlight = false
                self.stateLock.unlock()
                completion(model)
            }
        }
    }

    /// 同步算一遍（CLI 调试 / 自检用）
    func model() -> BarModel {
        var snaps = workbuddy.scan()
        snaps += copilot.scan()
        snaps += dsh.scan()
        snaps += externalStates()

        let now = Date()

        // 同一 provider+session 去重，取更新的那条
        var merged: [String: AgentSnapshot] = [:]
        for s in snaps {
            let key = Store.key(s)
            if let old = merged[key], old.updatedAt >= s.updatedAt { continue }
            merged[key] = s
        }

        // 长按菜单里隐藏 / 归档过的不再出现
        merged = merged.filter { AgentBarConfig.isVisible($0.key, now: now) }

        // 只看某一个
        if let focus = AgentBarConfig.focusKey, let only = merged[focus] {
            stateLock.lock()
            tick &+= 1
            let t = tick
            let today = cachedToday
            stateLock.unlock()
            return BarModel(primary: only, others: [], today: today, tick: t, focused: true)
        }

        // 记录「第一次出现」的时刻，作为缺 turnStartedAt 时的兜底锚点
        let stamp = nowMs()
        for key in merged.keys where firstSeen[key] == nil { firstSeen[key] = stamp }
        if firstSeen.count > merged.count {
            firstSeen = firstSeen.filter { merged[$0.key] != nil }
        }

        // 顺序：需要处理 > 进行中 > 已完成，从左到右；
        // 同组内按「本轮开始时间」从早到晚固定，完全同时才用 key 兜底。
        // 不用 updatedAt —— 它每轮都在变，卡片就会来回跳。
        let sorted = merged.values.sorted { a, b in
            if a.displayGroup != b.displayGroup { return a.displayGroup < b.displayGroup }
            let ka = Store.key(a), kb = Store.key(b)
            let sa = a.sortAnchor(firstSeen: firstSeen[ka] ?? stamp)
            let sb = b.sortAnchor(firstSeen: firstSeen[kb] ?? stamp)
            if sa != sb { return sa < sb }
            return ka < kb
        }

        stateLock.lock()
        tick &+= 1
        let t = tick
        let today = cachedToday
        stateLock.unlock()

        return BarModel(primary: sorted.first,
                        others: Array(sorted.dropFirst().prefix(3)),
                        today: today,
                        tick: t)
    }

    // MARK: - 今日统计（后台，60 秒一次）

    /// 必须在扫描队列上调用，否则会和适配器的缓存打架
    func refreshTodayIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard now - todayStamp >= 60 else { return }
        todayStamp = now
        var stats = workbuddy.todayStats()
        let dshUsage = dsh.todayUsage()
        if dshUsage.tokens > 0 { stats.tokens = dshUsage.tokens }
        stats.costCNY = dshUsage.cost
        stateLock.lock()
        cachedToday = stats
        stateLock.unlock()
    }

    /// 同步算一遍今日统计（CLI 调试用）
    func syncToday() {
        var stats = workbuddy.todayStats()
        let dshUsage = dsh.todayUsage()
        if dshUsage.tokens > 0 { stats.tokens = dshUsage.tokens }
        stats.costCNY = dshUsage.cost
        stateLock.lock()
        cachedToday = stats
        todayStamp = Date().timeIntervalSince1970
        stateLock.unlock()
    }

    // MARK: - 外部上报（~/.agentbar/state/*.json）

    private func externalStates() -> [AgentSnapshot] {
        let files = FileUtil.files(in: Paths.stateDir, matching: "json")
        guard !files.isEmpty else {
            if !externalCache.isEmpty { externalCache.removeAll() }
            return []
        }
        let now = Date()
        var out: [AgentSnapshot] = []
        var alive = Set<String>()

        for file in files {
            let stamp = FileStamp.read(file)
            guard stamp.size > 0 else { continue }
            let path = file.path
            alive.insert(path)
            if let cached = externalCache[path], cached.stamp == stamp {
                out.append(cached.snap)
                continue
            }
            let age = now.timeIntervalSince(Date(timeIntervalSince1970: stamp.mtime))
            if age > 600 { continue }                       // 10 分钟没更新视为失效
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = RawState(json: obj), raw.phase != .idle else { continue }
            let snap = raw.snapshot
            externalCache[path] = (stamp, snap)
            out.append(snap)
        }

        if externalCache.count > alive.count {
            externalCache = externalCache.filter { alive.contains($0.key) }
        }
        return out
    }
}
