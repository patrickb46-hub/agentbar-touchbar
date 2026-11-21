import AppKit

/// 一套配色。所有颜色都从这里取，渲染器里不再出现硬编码的白色/灰色，
/// 这样换主题（含浅色）才是真的换得掉。
struct Theme {
    var id: String
    var name: String
    var isLight: Bool
    var background: NSColor
    var primaryText: NSColor
    var secondaryText: NSColor
    var faintText: NSColor
    /// 胶囊 / 卡片叠在背景上的底与描边
    var surfaceFill: NSColor
    var surfaceStroke: NSColor
    /// 「← 全部」这类更实的按钮
    var strongFill: NSColor
    var strongStroke: NSColor
    var accent: NSColor
}

enum Themes {

    // MARK: - 预设

    static let midnight = Theme(
        id: "midnight", name: "深空", isLight: false,
        background: NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1),
        primaryText: NSColor(white: 0.95, alpha: 1),
        secondaryText: NSColor(white: 0.62, alpha: 1),
        faintText: NSColor(white: 0.42, alpha: 1),
        surfaceFill: NSColor(white: 1, alpha: 0.07),
        surfaceStroke: NSColor(white: 1, alpha: 0.14),
        strongFill: NSColor(white: 1, alpha: 0.08),
        strongStroke: NSColor(white: 1, alpha: 0.22),
        accent: NSColor(srgbRed: 0.29, green: 0.62, blue: 1.00, alpha: 1)
    )

    static let graphite = Theme(
        id: "graphite", name: "石墨", isLight: false,
        background: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1),
        primaryText: NSColor(white: 0.96, alpha: 1),
        secondaryText: NSColor(white: 0.66, alpha: 1),
        faintText: NSColor(white: 0.45, alpha: 1),
        surfaceFill: NSColor(white: 1, alpha: 0.08),
        surfaceStroke: NSColor(white: 1, alpha: 0.16),
        strongFill: NSColor(white: 1, alpha: 0.10),
        strongStroke: NSColor(white: 1, alpha: 0.26),
        accent: NSColor(white: 0.92, alpha: 1)
    )

    static let aurora = Theme(
        id: "aurora", name: "极光", isLight: false,
        background: NSColor(srgbRed: 0.024, green: 0.055, blue: 0.063, alpha: 1),
        primaryText: NSColor(white: 0.95, alpha: 1),
        secondaryText: NSColor(white: 0.60, alpha: 1),
        faintText: NSColor(white: 0.40, alpha: 1),
        surfaceFill: NSColor(srgbRed: 0.24, green: 0.82, blue: 0.68, alpha: 0.10),
        surfaceStroke: NSColor(srgbRed: 0.24, green: 0.82, blue: 0.68, alpha: 0.22),
        strongFill: NSColor(white: 1, alpha: 0.08),
        strongStroke: NSColor(white: 1, alpha: 0.20),
        accent: NSColor(srgbRed: 0.24, green: 0.82, blue: 0.68, alpha: 1)
    )

    static let amber = Theme(
        id: "amber", name: "暖阳", isLight: false,
        background: NSColor(srgbRed: 0.086, green: 0.063, blue: 0.043, alpha: 1),
        primaryText: NSColor(white: 0.96, alpha: 1),
        secondaryText: NSColor(white: 0.64, alpha: 1),
        faintText: NSColor(white: 0.44, alpha: 1),
        surfaceFill: NSColor(white: 1, alpha: 0.07),
        surfaceStroke: NSColor(white: 1, alpha: 0.15),
        strongFill: NSColor(white: 1, alpha: 0.09),
        strongStroke: NSColor(white: 1, alpha: 0.24),
        accent: NSColor(srgbRed: 1.00, green: 0.76, blue: 0.29, alpha: 1)
    )

    static let paper = Theme(
        id: "paper", name: "浅色", isLight: true,
        background: NSColor(srgbRed: 0.960, green: 0.960, blue: 0.969, alpha: 1),
        primaryText: NSColor(white: 0.13, alpha: 1),
        secondaryText: NSColor(white: 0.38, alpha: 1),
        faintText: NSColor(white: 0.55, alpha: 1),
        surfaceFill: NSColor(white: 0, alpha: 0.05),
        surfaceStroke: NSColor(white: 0, alpha: 0.12),
        strongFill: NSColor(white: 0, alpha: 0.06),
        strongStroke: NSColor(white: 0, alpha: 0.18),
        accent: NSColor(srgbRed: 0.15, green: 0.45, blue: 0.92, alpha: 1)
    )

    /// 面板里按顺序展示的预设
    static let presets: [Theme] = [midnight, graphite, aurora, amber, paper]

    static func preset(_ id: String?) -> Theme? { presets.first { $0.id == id } }

    // MARK: - 当前生效

    /// 自定义主题：底色 + 强调色由用户指定，文字色按底色亮度自动选深/浅
    static func custom(backgroundHex: String?, accentHex: String?) -> Theme {
        let bg = NSColor(hex: backgroundHex ?? "#0A0A0C") ?? midnight.background
        let light = bg.isLightBackground
        var t = light ? paper : midnight
        t.id = "custom"
        t.name = "自定义"
        t.isLight = light
        t.background = bg
        if let accent = NSColor(hex: accentHex ?? "")?.adaptedFor(light: light) {
            t.accent = accent
        }
        return t
    }

    /// 主题里所有「语义色」（阶段色、来源色）统一过一道对比度修正：
    /// 浅色底上把它们压暗一点，否则琥珀色几乎看不见。
    static func adapt(_ color: NSColor, light: Bool) -> NSColor {
        guard light else { return color }
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(srgbRed: c.redComponent * 0.78,
                       green: c.greenComponent * 0.72,
                       blue: c.blueComponent * 0.72,
                       alpha: c.alphaComponent)
    }
}

extension Theme {
    /// 变暗之后用的「提亮版」：不换配色风格，只把文字与描边的对比拉满 ——
    /// 同样一档背光下，深底上是纯白字压黑底，浅底上是近黑字。
    /// 只在 `TouchBarBacklight.dimmingStep >= 2`（系统已经把它调暗）时套用。
    func dimBoosted() -> Theme {
        var t = self
        if isLight {
            t.primaryText = NSColor(white: 0.02, alpha: 1)
            t.secondaryText = NSColor(white: 0.18, alpha: 1)
            t.faintText = NSColor(white: 0.34, alpha: 1)
            t.surfaceStroke = NSColor(white: 0, alpha: 0.18)
        } else {
            t.primaryText = NSColor(white: 1.0, alpha: 1)
            t.secondaryText = NSColor(white: 0.84, alpha: 1)
            t.faintText = NSColor(white: 0.62, alpha: 1)
            t.surfaceStroke = NSColor(white: 1, alpha: 0.22)
        }
        return t
    }
}

// MARK: - 颜色工具

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    /// 相对亮度够高就算浅色底
    var isLightBackground: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        return l > 0.45
    }

    func adaptedFor(light: Bool) -> NSColor { Themes.adapt(self, light: light) }
}
