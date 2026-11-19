import AppKit

enum BarAction {
    case focus, hide, archive, cancel
}

struct BarLayout {
    var approvalRect: NSRect?
    var primaryRect: NSRect?
    var cards: [(rect: NSRect, url: String?, cwd: String?, snapshot: AgentSnapshot)] = []
    var actions: [(rect: NSRect, kind: BarAction)] = []
    /// 「← 全部」退出单卡聚焦
    var exitFocusRect: NSRect?
}

enum BarStyle {
    static let height: CGFloat = 30
    static let padding: CGFloat = 24
    static let rightPadding: CGFloat = 12
    static let background = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1)
    static let primaryText = NSColor(white: 0.95, alpha: 1)
    static let secondaryText = NSColor(white: 0.62, alpha: 1)
    static let faintText = NSColor(white: 0.42, alpha: 1)

    static let statusFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    static let chipFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    static let cardFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let smallFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    static let smallMono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
}

enum BarRenderer {

    @discardableResult
    static func draw(_ model: BarModel, in rect: NSRect,
                     action target: AgentSnapshot? = nil) -> BarLayout {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return BarLayout() }

        ctx.setFillColor(BarStyle.background.cgColor)
        ctx.fill(rect)

        if let target { return drawActionRow(target, in: rect) }

        var agents: [AgentSnapshot] = []
        if let primary = model.primary { agents.append(primary) }
        agents.append(contentsOf: model.others)
        agents = agents.filter { $0.isLive || $0.phase == .done }

        if agents.count >= 2 {
            return drawCards(agents, in: rect)
        }
        if let single = agents.first {
            return drawSingle(single, others: [], today: model.today, in: rect)
        }
        drawIdle(model, in: rect)
        return BarLayout()
    }

    // MARK: - 长按后的操作行

    private static func drawActionRow(_ target: AgentSnapshot, in rect: NSRect) -> BarLayout {
        var layout = BarLayout()
        let accent = providerTint(target.provider)
        var x = BarStyle.padding

        let dotRect = NSRect(x: x + 3, y: rect.midY - 3, width: 6, height: 6)
        target.phase.tint.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        x += 16
        x += text(target.project, x: x, font: BarStyle.cardFont,
                  color: NSColor(white: 0.95, alpha: 1), maxWidth: 180) + 18

        let items: [(String, BarAction, NSColor)] = [
            ("只看这个", .focus, accent),
            ("隐藏 2 小时", .hide, BarStyle.secondaryText),
            ("归档", .archive, NSColor(srgbRed: 1.0, green: 0.45, blue: 0.42, alpha: 1)),
            ("取消", .cancel, BarStyle.faintText)
        ]

        for (label, kind, color) in items {
            let w = measure(label, font: BarStyle.chipFont) + 22
            guard x + w < rect.maxX - BarStyle.rightPadding else { break }
            let r = NSRect(x: x, y: rect.midY - 10, width: w, height: 20)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            color.withAlphaComponent(0.16).setFill()
            path.fill()
            color.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
            let tw = measure(label, font: BarStyle.chipFont)
            _ = text(label, x: r.minX + (r.width - tw) / 2, font: BarStyle.chipFont,
                     color: NSColor(white: 0.95, alpha: 1), maxWidth: r.width)
            layout.actions.append((r, kind))
            x += w + 8
        }

        layout.primaryRect = NSRect(x: 0, y: 0, width: rect.width, height: rect.height)
        return layout
    }

    // MARK: - 多进程：每个 agent 一个彩色卡片，点哪个跳哪个

    private static func drawCards(_ agents: [AgentSnapshot], in rect: NSRect) -> BarLayout {
        var layout = BarLayout()
        let shown = Array(agents.prefix(4))
        let gap: CGFloat = 8
        let avail = rect.width - BarStyle.padding - BarStyle.rightPadding - gap * CGFloat(shown.count - 1)
        guard avail > 0 else { return layout }
        let cardWidth = avail / CGFloat(shown.count)

        for (index, agent) in shown.enumerated() {
            let x = BarStyle.padding + (cardWidth + gap) * CGFloat(index)
            let cardRect = NSRect(x: x, y: 5, width: cardWidth, height: 20)
            let accent = providerTint(agent.provider)
            let path = NSBezierPath(roundedRect: cardRect, xRadius: 6, yRadius: 6)
            accent.withAlphaComponent(agent.phase == .waitingApproval ? 0.24 : 0.13).setFill()
            path.fill()
            accent.withAlphaComponent(agent.phase == .waitingApproval ? 0.85 : 0.45).setStroke()
            path.lineWidth = 1
            path.stroke()

            // 状态点
            let dotCenter = NSPoint(x: cardRect.minX + 11, y: cardRect.midY)
            let dot = NSBezierPath(ovalIn: NSRect(x: dotCenter.x - 3, y: dotCenter.y - 3, width: 6, height: 6))
            switch agent.phase {
            case .waitingApproval:
                NSColor.clear.setFill()
                dot.fill()
                agent.phase.tint.setStroke()
                dot.lineWidth = 1.5
                dot.stroke()
            case .done:
                agent.phase.tint.withAlphaComponent(0.55).setFill()
                dot.fill()
            default:
                agent.phase.tint.setFill()
                dot.fill()
            }

            // 右侧信息
            let info: String
            let infoColor: NSColor
            switch agent.phase {
            case .waitingApproval:
                info = "待确认"
                infoColor = agent.phase.tint
            case .done:
                info = "完成"
                infoColor = agent.phase.tint.withAlphaComponent(0.8)
            default:
                info = (agent.elapsed ?? 0) > 0 ? clockText(agent.elapsed ?? 0) : "进行中"
                infoColor = BarStyle.faintText
            }
            let infoFont = agent.phase == .waitingApproval ? BarStyle.chipFont : BarStyle.smallMono
            let infoWidth = measure(info, font: infoFont)
            _ = text(info, x: cardRect.maxX - 9 - infoWidth, font: infoFont, color: infoColor,
                     maxWidth: infoWidth + 2)

            // 中间：软件名 · 项目名（窄卡片只留项目名，靠底色区分软件）
            let textX = dotCenter.x + 9
            let textMax = cardRect.maxX - 9 - infoWidth - 8 - textX
            if textMax > 16 {
                let label = cardWidth >= 210
                    ? "\(providerShort(agent.provider)) · \(agent.project)"
                    : agent.project
                _ = text(label, x: textX, font: BarStyle.cardFont,
                         color: NSColor(white: agent.phase == .done ? 0.68 : 0.94, alpha: 1),
                         maxWidth: textMax)
            }

            layout.cards.append((cardRect, agent.jumpUrl, agent.cwd, agent))
        }
        return layout
    }

    // MARK: - 单个 agent：左栏实时状态，右栏今日总量

    private static func drawSingle(_ primary: AgentSnapshot, others: [AgentSnapshot],
                                   today: TodayStats, in rect: NSRect) -> BarLayout {
        var layout = BarLayout()
        let rightEdge = rect.maxX - BarStyle.rightPadding
        var x = BarStyle.padding

        // 右侧要预留多少：今日轮次 + 可能的按钮
        let summary = composeSummary(today, primary: primary, maxWidth: min(260, rect.width * 0.46))
        let summaryW = summary.map { measure($0, font: BarStyle.smallMono) } ?? 0
        let showsButton = primary.phase == .waitingApproval || primary.phase == .done
        let buttonLabel = primary.phase == .done ? "打开会话" : "跳回会话"
        let buttonW = showsButton ? measure(buttonLabel, font: BarStyle.chipFont) + 26 : 0

        let exitW: CGFloat = AgentBarConfig.focusKey != nil
            ? measure("← 全部", font: BarStyle.chipFont) + 22 : 0

        var reserve: CGFloat = 0
        if summaryW > 0 { reserve += summaryW + 16 }
        if buttonW > 0 { reserve += buttonW + 12 }
        if exitW > 0 { reserve += exitW + 10 }

        // 状态灯
        let center = NSPoint(x: x + 5, y: rect.midY)
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
        primary.phase.tint.withAlphaComponent(0.20).setFill()
        ring.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        primary.phase.tint.setFill()
        dot.fill()
        x += 22

        // 状态词
        let statusText = (primary.phase == .waitingApproval && primary.note == "疑似")
            ? "可能待确认" : primary.phase.label
        x += text(statusText, x: x, font: BarStyle.statusFont, color: primary.phase.tint) + 14

        // 秒表 / 本轮耗时
        if let seconds = primary.elapsed ?? primary.turnDuration {
            x += text(clockText(seconds), x: x, font: BarStyle.monoFont, color: BarStyle.secondaryText) + 16
        }

        // 尾部元素先算宽度，剩下的才是项目名的
        var chipLabel: String?
        if let tool = primary.tool, !tool.isEmpty, primary.phase != .done {
            chipLabel = shortTool(tool)
        }
        let chipW = chipLabel.map { measure($0, font: BarStyle.chipFont) + 18 + 12 } ?? 0
        let liveOthers = others.filter { $0.isLive }
        let othersW: CGFloat = liveOthers.isEmpty ? 0 : measure("+\(liveOthers.count)", font: BarStyle.chipFont) + 12

        let sepW: CGFloat = 12
        let projectMax = max(48, rightEdge - reserve - x - sepW - chipW - othersW - 8)
        x += text("·", x: x, font: BarStyle.bodyFont, color: BarStyle.faintText) + sepW
        x += text(primary.project, x: x, font: BarStyle.bodyFont, color: BarStyle.primaryText,
                  maxWidth: projectMax) + 12

        if let label = chipLabel {
            x = chip(label, x: x) + 12
        }
        if !liveOthers.isEmpty {
            x += text("+\(liveOthers.count)", x: x, font: BarStyle.chipFont, color: BarStyle.faintText) + 12
        }

        // 今日轮次贴右（有退出按钮时让位）
        let summaryRightEdge = rightEdge - (exitW > 0 ? exitW + 10 : 0)
        if let summary {
            let textX = summaryRightEdge - summaryW
            if textX > x + 24 {
                _ = text(summary, x: textX, font: BarStyle.smallMono, color: BarStyle.secondaryText)
            }
        }

        // 跳回按钮：贴着左侧内容放，放不下再退到右侧
        if showsButton {
            var originX = x + 6
            if originX + buttonW > rightEdge - summaryW - 16 {
                originX = max(BarStyle.padding, rightEdge - summaryW - 16 - buttonW)
            }
            let r = NSRect(x: originX, y: rect.midY - 10, width: buttonW, height: 20)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            primary.phase.tint.withAlphaComponent(primary.phase == .done ? 0.18 : 0.24).setFill()
            path.fill()
            primary.phase.tint.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 1
            path.stroke()
            let tw = measure(buttonLabel, font: BarStyle.chipFont)
            _ = text(buttonLabel, x: r.minX + (r.width - tw) / 2, font: BarStyle.chipFont,
                     color: NSColor(white: 1, alpha: 0.95), maxWidth: r.width)
            layout.approvalRect = r
        }

        if exitW > 0 {
            let r = NSRect(x: rightEdge - exitW, y: rect.midY - 10, width: exitW, height: 20)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            NSColor(white: 1, alpha: 0.08).setFill()
            path.fill()
            NSColor(white: 1, alpha: 0.22).setStroke()
            path.lineWidth = 1
            path.stroke()
            let label = "← 全部"
            let tw = measure(label, font: BarStyle.chipFont)
            _ = text(label, x: r.minX + (r.width - tw) / 2, font: BarStyle.chipFont,
                     color: NSColor(white: 0.9, alpha: 1), maxWidth: r.width)
            layout.exitFocusRect = r
        }

        layout.primaryRect = NSRect(x: 0, y: 0, width: rect.width, height: rect.height)
        layout.cards.append((layout.primaryRect!, primary.jumpUrl, primary.cwd, primary))
        return layout
    }

    // MARK: - 空闲：左栏今日总量，右栏宠物

    private static func drawIdle(_ model: BarModel, in rect: NSRect) {
        let today = model.today
        var x = BarStyle.padding

        if today.isEmpty {
            x += text("AgentBar · 暂无 AI 活动", x: x, font: BarStyle.bodyFont, color: BarStyle.faintText) + 12
        } else {
            x += text("今日", x: x, font: BarStyle.bodyFont, color: BarStyle.faintText) + 10
            x += text("\(today.turns) 轮", x: x, font: BarStyle.statusFont, color: BarStyle.primaryText) + 14
            x += text("·", x: x, font: BarStyle.bodyFont, color: BarStyle.faintText) + 12
            x += text(today.durationText, x: x, font: BarStyle.monoFont, color: BarStyle.primaryText) + 14
            if today.credits > 0 {
                x += text("·", x: x, font: BarStyle.bodyFont, color: BarStyle.faintText) + 12
                x += text(String(format: "%.1f 积分", today.credits), x: x,
                          font: BarStyle.bodyFont, color: BarStyle.secondaryText) + 12
            }
            if let tokens = today.tokensText {
                x += text("·", x: x, font: BarStyle.bodyFont, color: BarStyle.faintText) + 12
                x += text(tokens, x: x, font: BarStyle.monoFont, color: BarStyle.secondaryText) + 12
            }
            if let cost = today.costText {
                x += text("·", x: x, font: BarStyle.bodyFont, color: BarStyle.faintText) + 12
                x += text(cost, x: x, font: BarStyle.monoFont, color: BarStyle.primaryText) + 12
            }
        }

        guard rect.width > 420 else { return }

        // 宠物贴右
        let petSize: CGFloat = 26
        let petRect = NSRect(x: rect.maxX - BarStyle.rightPadding - petSize,
                             y: rect.midY - petSize / 2,
                             width: petSize, height: petSize)
        Pet.draw(frame: model.tick, tint: Phase.thinking.tint, in: petRect)

        let caption = "待命中"
        let w = measure(caption, font: BarStyle.smallFont)
        if petRect.minX - w - 10 > x + 24 {
            _ = text(caption, x: petRect.minX - w - 10, font: BarStyle.smallFont, color: BarStyle.faintText)
        }
    }

    /// 按优先级拼右栏摘要，放不下的部分自动丢掉
    private static func composeSummary(_ today: TodayStats, primary: AgentSnapshot?,
                                      maxWidth: CGFloat) -> String? {
        var parts: [String] = []
        if today.turns > 0 { parts.append("今日 \(today.turns) 轮") }
        // 金额与 token 优先显示「本会话」，避免拿全天的总量冒充
        if let tokens = primary?.tokens, tokens > 0 {
            parts.append("本会话 " + compactTokens(tokens))
        }
        if let cost = primary?.costCNY, cost > 0 { parts.append(costText(cost)) }
        if parts.count == 1, today.credits > 0 {
            parts.append(String(format: "%.1f 分", today.credits))
        }
        guard !parts.isEmpty else { return nil }

        var chosen: [String] = []
        for part in parts {
            let candidate = (chosen + [part]).joined(separator: " · ")
            if measure(candidate, font: BarStyle.smallMono) <= maxWidth {
                chosen.append(part)
            }
        }
        return chosen.isEmpty ? parts[0] : chosen.joined(separator: " · ")
    }

    // MARK: - 标尺（量真实宽度用）

    static func drawRuler(in rect: NSRect) {
        BarStyle.background.setFill()
        rect.fill()

        var tick: CGFloat = 0
        while tick <= rect.width {
            let major = Int(tick) % 50 == 0
            let h: CGFloat = major ? 17 : 8
            let lineRect = NSRect(x: tick, y: 0, width: 1, height: h)
            if major {
                NSColor(white: 0.95, alpha: 0.9).setFill()
            } else {
                NSColor(white: 0.5, alpha: 0.7).setFill()
            }
            lineRect.fill()
            if major, tick < rect.width - 8 {
                _ = text("\(Int(tick))", x: tick + 3, font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                         color: NSColor(white: 0.85, alpha: 1), maxWidth: 44)
            }
            tick += 25
        }

        // 末端标记：看不到它说明宽度被裁掉了
        let label = "END@\(Int(rect.width))"
        let boldFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        let w = measure(label, font: boldFont)
        if rect.width > w + 8 {
            _ = text(label, x: rect.width - w - 6, font: boldFont,
                     color: NSColor(srgbRed: 1, green: 0.35, blue: 0.35, alpha: 1), maxWidth: w + 2)
        }
    }

    // MARK: - 绘制原语

    @discardableResult
    static func text(_ s: String, x: CGFloat, font: NSFont, color: NSColor,
                     maxWidth: CGFloat = 400) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attr = NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let y = (BarStyle.height - lineHeight) / 2
        attr.draw(in: NSRect(x: x, y: y, width: maxWidth, height: lineHeight))
        return min(ceil(attr.size().width), maxWidth)
    }

    static func compactTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM tok", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk tok", Double(n) / 1000) }
        return "\(n) tok"
    }

    static func costText(_ cost: Double) -> String {
        cost < 0.01 ? "<¥0.01" : String(format: "¥%.2f", cost)
    }

    static func measure(_ s: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width)
    }

    private static func chip(_ label: String, x: CGFloat) -> CGFloat {
        let w = measure(label, font: BarStyle.chipFont) + 18
        let r = NSRect(x: x, y: BarStyle.height / 2 - 9.5, width: w, height: 19)
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        NSColor(white: 1, alpha: 0.07).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
        let tw = measure(label, font: BarStyle.chipFont)
        _ = text(label, x: r.minX + (r.width - tw) / 2, font: BarStyle.chipFont,
                 color: NSColor(white: 0.85, alpha: 1), maxWidth: r.width)
        return r.maxX
    }

    private static func shortTool(_ tool: String) -> String {
        switch tool {
        case "Bash": return "Bash"
        case "Read": return "Read"
        case "Write", "Edit", "MultiEdit": return "Edit"
        case "WebSearch", "WebFetch": return "Web"
        default: return String(tool.prefix(10))
        }
    }
}

// MARK: - 像素小内核

enum Pet {
    /// 12×12 像素网格，逐格画方块，随帧走动
    static func draw(frame: Int, tint: NSColor, in rect: NSRect) {
        let unit = rect.width / 12.0
        let step = frame / 4
        let walking = step % 2 == 0
        let bob: CGFloat = walking ? 0 : -1

        func px(_ gx: Int, _ gy: Int, _ w: Int = 1, _ h: Int = 1, _ color: NSColor) {
            let r = NSRect(x: rect.minX + CGFloat(gx) * unit,
                           y: rect.minY + CGFloat(gy) * unit,
                           width: CGFloat(w) * unit,
                           height: CGFloat(h) * unit)
            color.setFill()
            r.fill()
        }

        let body = NSColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1)
        let edge = NSColor(white: 1, alpha: 0.35)

        px(3, 0, 6, 1, NSColor(white: 1, alpha: 0.08))

        let bx = 2, by = 3
        let bodyRect = NSRect(x: rect.minX + CGFloat(bx) * unit,
                              y: rect.minY + CGFloat(by) * unit + bob * unit,
                              width: 8 * unit, height: 7 * unit)
        let path = NSBezierPath(roundedRect: bodyRect, xRadius: unit * 1.4, yRadius: unit * 1.4)
        body.setFill()
        path.fill()
        edge.setStroke()
        path.lineWidth = max(0.8, unit * 0.18)
        path.stroke()

        let eyeY = by + 4
        px(bx + 2, eyeY, 1, 1, tint)
        px(bx + 5, eyeY, 1, 1, tint)
        px(bx + 3, by + 2, 2, 1, NSColor(white: 0.45, alpha: 1))

        let leftUp = walking ? 0 : 1
        px(bx + 1, by - 1 + leftUp, 2, 1, body)
        px(bx + 5, by - 1 + (1 - leftUp), 2, 1, body)

        px(bx + 3, by + 8, 1, 1, tint.withAlphaComponent(frame % 12 < 8 ? 0.95 : 0.25))
    }
}
