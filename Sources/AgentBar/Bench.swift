import Foundation

/// 性能基准：把「每秒都在跑的那条路径」单独量出来。
///
///   agentbar bench            # 扫 20 次，报平均 / 最慢
///   agentbar bench --iters 50
///   agentbar bench --today    # 顺带量今日统计
///
/// 改扫描逻辑前后各跑一次，数字才说明问题。
enum Bench {

    static func run(_ args: [String]) {
        var kv: [String: String] = [:]
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("--") {
                let key = String(args[i].dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { kv[key] = args[i + 1]; i += 2 }
                else { kv[key] = "true"; i += 1 }
            } else { i += 1 }
        }

        let iters = max(1, Int(kv["iters"] ?? "20") ?? 20)
        print("扫描基准（\(iters) 次）")

        // 预热：首次要建候选列表、读日志，不能算进平均
        _ = Store.shared.model()

        var samples: [Double] = []
        samples.reserveCapacity(iters)
        for _ in 0..<iters {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = Store.shared.model()
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            samples.append(dt)
        }
        report(samples, label: "扫描（每次 = 一个刷新周期）")

        if kv["today"] != nil {
            var tSamples: [Double] = []
            for _ in 0..<3 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                Store.shared.syncToday()
                tSamples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            }
            report(tSamples, label: "今日统计")
        }
    }

    private static func report(_ samples: [Double], label: String) {
        let sorted = samples.sorted()
        let avg = samples.reduce(0, +) / Double(samples.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print(String(format: "  %@：平均 %.3f ms  中位 %.3f ms  p95 %.3f ms  最慢 %.3f ms",
                     label, avg, sorted[sorted.count / 2], p95, sorted.last ?? 0))
    }
}
