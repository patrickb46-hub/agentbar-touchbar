import Foundation
import CoreGraphics

enum AgentBarConfig {

    private static let configURL = Paths.root.appendingPathComponent("config.json")

    private static var store: [String: Any] = {
        guard let data = try? Data(contentsOf: Paths.root.appendingPathComponent("config.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }()

    /// Touch Bar 应用区宽度（点）。启动后会从 _NSFunctionRowPanel 实测并自动纠正。
    static var barWidth: CGFloat {
        if let raw = ProcessInfo.processInfo.environment["AGENTBAR_WIDTH"], let v = Double(raw) {
            return CGFloat(v)
        }
        return 765
    }

    /// 右侧控制条（亮度/音量/Siri）占走的宽度。这一块在 panel 内部，
    /// 会盖住我们的画布，必须扣掉。可用「校准右侧边界」重新测量。
    static var reservedRight: CGFloat {
        if let raw = ProcessInfo.processInfo.environment["AGENTBAR_RESERVED_RIGHT"], let v = Double(raw) {
            return CGFloat(v)
        }
        if let v = store["reservedRight"] as? NSNumber { return CGFloat(v.doubleValue) }
        return 85
    }

    static func setReservedRight(_ value: CGFloat) {
        store["reservedRight"] = Double(round(value))
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        else { return }
        Paths.ensure()
        try? data.write(to: configURL)
    }

    /// 标尺模式：画刻度，用来量出这台机器上应用区的真实宽度
    static var rulerMode: Bool {
        ProcessInfo.processInfo.environment["AGENTBAR_RULER"] == "1"
    }

    static var rulerWidth: CGFloat { 1200 }

    /// 调试用：忽略「太旧就不显示」的过滤
    static var ignoreAge: Bool {
        ProcessInfo.processInfo.environment["AGENTBAR_IGNORE_AGE"] == "1"
    }
}
