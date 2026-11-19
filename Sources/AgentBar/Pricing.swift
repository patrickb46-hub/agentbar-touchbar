import Foundation

/// DeepSeek 官方价格（元 / 百万 token）。
/// 来源：api-docs.deepseek.com/zh-cn/quick_start/pricing
/// 空闲时段为高峰时段的一半；高峰 = 北京时间工作日 9:00-12:00 / 14:00-18:00。
enum Pricing {

    struct Rate {
        var cacheHit: Double
        var cacheMiss: Double
        var output: Double
    }

    static func isPeak(_ date: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let comps = cal.dateComponents([.weekday, .hour], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour else { return false }
        if weekday == 1 || weekday == 7 { return false }          // 周末全天空闲
        return (9...11).contains(hour) || (14...17).contains(hour)
    }

    /// 空闲时段单价
    static func offPeakRate(model: String) -> Rate {
        let m = model.lowercased()
        if m.contains("pro") {
            return Rate(cacheHit: 0.15, cacheMiss: 4.5, output: 13.5)
        }
        // deepseek-flash / deepseek-v4-flash / deepseek-v4.1-flash
        return Rate(cacheHit: 0.04, cacheMiss: 1.0, output: 4.0)
    }

    static func cost(cacheReadTokens: Int, uncachedInputTokens: Int, outputTokens: Int,
                     model: String, at date: Date = Date()) -> Double {
        var rate = offPeakRate(model: model)
        if isPeak(date) {
            rate.cacheHit *= 2
            rate.cacheMiss *= 2
            rate.output *= 2
        }
        let cost = Double(cacheReadTokens) * rate.cacheHit / 1_000_000
            + Double(uncachedInputTokens) * rate.cacheMiss / 1_000_000
            + Double(outputTokens) * rate.output / 1_000_000
        return cost
    }
}
