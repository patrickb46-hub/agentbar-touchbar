import AppKit
import SwiftUI

/// 面板要回调 App 的动作，避免 SwiftUI 直接摸 AppDelegate 的私有方法
protocol PanelActions: AnyObject {
    func panelSetEnabled(_ on: Bool)
    func panelRemount()
    func panelCalibrate()
    func panelRestoreHidden()
    func panelExportPreview()
    func panelOpenStateDir()
    func panelOpenLog()
    func panelQuit()
    func panelAutostart(_ on: Bool) -> Bool
    func panelIsAutostart() -> Bool
    func panelRefreshNow()
    func panelSetKeepLit(_ on: Bool) -> String
    func panelOpenAccessibilitySettings()
}

/// 面板的数据源。所有改动直接落到 AgentBarConfig，Touch Bar 下一帧就跟着变。
final class ControlCenter: ObservableObject {
    @Published var enabled: Bool = AgentBarConfig.enabled
    @Published var themeId: String = AgentBarConfig.themeId
    @Published var accent: Color = Color(nsColor: AgentBarConfig.theme.accent)
    @Published var background: Color = Color(nsColor: AgentBarConfig.theme.background)
    @Published var custom: Bool = false
    @Published var structure: Structure = AgentBarConfig.structure
    @Published var refresh: Double = AgentBarConfig.refreshSeconds
    @Published var menuTitle: Bool = AgentBarConfig.menuTitle
    @Published var autostart: Bool = false
    /// 常亮开关与实时状态（「生效中 · 拉回 3 次」）
    @Published var keepLit: Bool = AgentBarConfig.keepLit
    @Published var keepLitStatus: String = "—"
    /// 降级到模拟输入、但还没拿到辅助功能权限
    @Published var keepLitNeedsPermission: Bool = false
    @Published var attached: Bool = false
    @Published var cpu: String = "—"
    /// 配置版本号：改一次 +1，预览条靠它重画
    @Published var revision: Int = AgentBarConfig.revision

    /// 由 AppDelegate 每次刷新后推进来
    @Published var statusLine: String = "读取中…"
    @Published var detailLine: String = ""
    @Published var model: BarModel?

    private weak var panelActions: PanelActions?

    init(actions: PanelActions) {
        self.panelActions = actions
        self.custom = AgentBarConfig.accentHex != nil || AgentBarConfig.backgroundHex != nil
        self.autostart = actions.panelIsAutostart()
    }

    var actions: PanelActions? { panelActions }

    func applyEnabled() { revision = AgentBarConfig.revision; panelActions?.panelSetEnabled(enabled) }

    func applyTheme(_ id: String) {
        themeId = id
        AgentBarConfig.setTheme(id)
        // 选预设就清掉自定义色，否则会盖住预设
        AgentBarConfig.setAccent(nil)
        AgentBarConfig.setBackground(nil)
        custom = false
        syncColors()
        revision = AgentBarConfig.revision
    }

    func applyAccent() {
        AgentBarConfig.setAccent(accent.hex)
        custom = true
        syncColors()
        revision = AgentBarConfig.revision
    }

    func applyBackground() {
        AgentBarConfig.setBackground(background.hex)
        custom = true
        syncColors()
        revision = AgentBarConfig.revision
    }

    func resetColors() {
        AgentBarConfig.setAccent(nil)
        AgentBarConfig.setBackground(nil)
        custom = false
        syncColors()
        revision = AgentBarConfig.revision
    }

    func applyStructure() { AgentBarConfig.setStructure(structure); revision = AgentBarConfig.revision }

    func applyRefresh() { AgentBarConfig.setRefresh(refresh); revision = AgentBarConfig.revision }

    func applyMenuTitle() { AgentBarConfig.menuTitle = menuTitle; revision = AgentBarConfig.revision }

    func applyAutostart() { autostart = panelActions?.panelAutostart(autostart) ?? false }

    func applyKeepLit() {
        keepLitStatus = panelActions?.panelSetKeepLit(keepLit) ?? "—"
        keepLitNeedsPermission = TouchBarBacklight.shared.state == .needsPermission
        revision = AgentBarConfig.revision
    }

    func syncColors() {
        let theme = AgentBarConfig.theme
        accent = Color(nsColor: theme.accent)
        background = Color(nsColor: theme.background)
    }

    func refreshFromConfig() {
        revision = AgentBarConfig.revision
        enabled = AgentBarConfig.enabled
        themeId = AgentBarConfig.themeId
        structure = AgentBarConfig.structure
        refresh = AgentBarConfig.refreshSeconds
        menuTitle = AgentBarConfig.menuTitle
        keepLit = AgentBarConfig.keepLit
    }
}

extension Color {
    var hex: String { NSColor(self).hexString }
}

// MARK: - 原生取色块

private struct NativeColorWell: NSViewRepresentable {
    var nsColor: NSColor
    var onChange: (NSColor) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (NSColor) -> Void
        init(onChange: @escaping (NSColor) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSColorWell) { onChange(sender.color) }
    }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        well.color = nsColor
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        well.toolTip = "点一下换颜色"
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.onChange = onChange
        if well.color != nsColor { well.color = nsColor }
    }
}

// MARK: - 预览条（和 Touch Bar 用同一套渲染器）

private final class PreviewBarView: NSView {
    var model: BarModel?
    var revision: Int = 0

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        BarStyle.theme = AgentBarConfig.theme
        BarStyle.structure = AgentBarConfig.structure
        guard let model else {
            BarStyle.background.setFill()
            bounds.fill()
            return
        }
        _ = BarRenderer.draw(model, in: bounds)
    }
}

private struct PreviewStrip: NSViewRepresentable {
    var model: BarModel?
    var revision: Int

    func makeNSView(context: Context) -> PreviewBarView {
        let v = PreviewBarView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: PreviewBarView, context: Context) {
        v.model = model
        v.revision = revision
        v.needsDisplay = true
    }
}

// MARK: - 面板尺寸（面板和 popover 必须用同一份，否则内容会被裁）

enum PanelMetrics {
    static let width: CGFloat = 400
    static let height: CGFloat = 580
    static let minWidth: CGFloat = 360
    static let minHeight: CGFloat = 520
    static var size: NSSize { NSSize(width: width, height: height) }
}

struct PanelView: View {
    @ObservedObject var center: ControlCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    previewCard
                    powerCard
                    appearanceCard
                    structureCard
                    behaviorCard
                    actionsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
        }
        .frame(minWidth: PanelMetrics.minWidth, minHeight: PanelMetrics.minHeight,
               alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(center.enabled ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray))
                .frame(width: 7, height: 7)
            Text(center.statusLine)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(headerSubtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var headerSubtitle: String {
        guard center.enabled else { return "已暂停" }
        let state = center.attached ? "已接管" : "仅菜单栏"
        return center.cpu == "—" ? state : "\(state) · CPU \(center.cpu)"
    }

    // MARK: 预览

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            PreviewStrip(model: center.model, revision: center.revision)
                .frame(height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            if !center.detailLine.isEmpty {
                Text(center.detailLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: 开关

    private var powerCard: some View {
        Toggle(isOn: Binding(
            get: { center.enabled },
            set: { center.enabled = $0; center.applyEnabled() }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("接管 Touch Bar").font(.system(size: 12.5, weight: .medium))
                Text("关掉后彻底让出，也不再读日志")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: 外观

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("外观")
            HStack(spacing: 8) {
                ForEach(Themes.presets, id: \.id) { t in
                    Button {
                        center.applyTheme(t.id)
                    } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: t.background))
                                    .frame(height: 22)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(center.themeId == t.id && !center.custom
                                                          ? Color.accentColor : Color.primary.opacity(0.15),
                                                          lineWidth: center.themeId == t.id && !center.custom ? 2 : 1)
                                    )
                                Circle()
                                    .fill(Color(nsColor: t.accent))
                                    .frame(width: 8, height: 8)
                            }
                            Text(t.name)
                                .font(.system(size: 9.5, weight: center.themeId == t.id && !center.custom
                                              ? .semibold : .regular))
                                .foregroundStyle(center.themeId == t.id && !center.custom
                                                 ? Color.primary : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 5) {
                colorRow("强调色", binding: Binding(
                    get: { center.accent },
                    set: { center.accent = $0; center.applyAccent() }
                ))
                HStack(spacing: 8) {
                    colorRow("背景", binding: Binding(
                        get: { center.background },
                        set: { center.background = $0; center.applyBackground() }
                    ))
                    Spacer(minLength: 0)
                    if center.custom {
                        Button("还原预设") { center.resetColors() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }
        }
    }

    private func colorRow(_ title: String, binding: Binding<Color>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            NativeColorWell(nsColor: NSColor(binding.wrappedValue)) { picked in
                binding.wrappedValue = Color(nsColor: picked)
            }
            .frame(width: 44, height: 22)
            Spacer(minLength: 0)
        }
    }

    // MARK: 显示结构

    private var structureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("显示结构")
            let binding = Binding<Structure>(
                get: { center.structure },
                set: { center.structure = $0; center.applyStructure() }
            )
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 5) {
                toggleChip("状态灯", isOn: Binding(
                    get: { binding.wrappedValue.showDot },
                    set: { var s = binding.wrappedValue; s.showDot = $0; binding.wrappedValue = s }))
                toggleChip("耗时", isOn: Binding(
                    get: { binding.wrappedValue.showElapsed },
                    set: { var s = binding.wrappedValue; s.showElapsed = $0; binding.wrappedValue = s }))
                toggleChip("会话名", isOn: Binding(
                    get: { binding.wrappedValue.showProject },
                    set: { var s = binding.wrappedValue; s.showProject = $0; binding.wrappedValue = s }))
                toggleChip("工具标签", isOn: Binding(
                    get: { binding.wrappedValue.showTool },
                    set: { var s = binding.wrappedValue; s.showTool = $0; binding.wrappedValue = s }))
                toggleChip("今日统计", isOn: Binding(
                    get: { binding.wrappedValue.showSummary },
                    set: { var s = binding.wrappedValue; s.showSummary = $0; binding.wrappedValue = s }))
                toggleChip("小内核", isOn: Binding(
                    get: { binding.wrappedValue.showPet },
                    set: { var s = binding.wrappedValue; s.showPet = $0; binding.wrappedValue = s }))
            }

            HStack(spacing: 8) {
                Text("最多卡片").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { center.structure.maxCards },
                    set: { var s = center.structure; s.maxCards = $0; center.structure = s; center.applyStructure() }
                )) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
        }
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isOn.wrappedValue ? 0.06 : 0.02))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 行为

    private var behaviorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("行为")
            HStack(spacing: 8) {
                Text("刷新频率").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { center.refresh },
                    set: { center.refresh = $0; center.applyRefresh() }
                )) {
                    Text("0.5s").tag(0.5)
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                Spacer(minLength: 0)
            }
            Toggle(isOn: Binding(
                get: { center.menuTitle },
                set: { center.menuTitle = $0; center.applyMenuTitle() }
            )) {
                Text("菜单栏显示状态文字").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            Toggle(isOn: Binding(
                get: { center.autostart },
                set: { center.autostart = $0; center.applyAutostart() }
            )) {
                Text("登录时自动启动").font(.system(size: 12))
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { center.keepLit },
                set: { center.keepLit = $0; center.applyKeepLit() }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("保持常亮").font(.system(size: 12))
                    Text(center.keepLit ? center.keepLitStatus : "闲置后照系统默认变暗、熄灭")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.switch)
            .help("系统默认：60 秒没碰就调暗，再过十几秒全灭。打开后按回原亮度；系统不给背光句柄时改用模拟输入顶住闲置计时器。代价：OLED 一直亮着老化快一点。")

            if center.keepLit && center.keepLitNeedsPermission {
                HStack(spacing: 8) {
                    Text("系统设置 → 隐私与安全性 → 辅助功能：列表里旧的 AgentBar 条目先删掉，再重新勾上")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    smallButton("去授权") { center.actions?.panelOpenAccessibilitySettings() }
                }
            }
        }
    }

    // MARK: 动作

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("维护")
            HStack(spacing: 6) {
                smallButton("重新挂载") { center.enabled = true; center.applyEnabled(); center.actions?.panelRemount() }
                smallButton("校准边界") { center.actions?.panelCalibrate() }
                smallButton("恢复隐藏项") { center.actions?.panelRestoreHidden() }
            }
            HStack(spacing: 6) {
                smallButton("导出预览图") { center.actions?.panelExportPreview() }
                smallButton("状态目录") { center.actions?.panelOpenStateDir() }
                smallButton("打开日志") { center.actions?.panelOpenLog() }
            }
            HStack(spacing: 6) {
                smallButton("立即刷新") { center.actions?.panelRefreshNow() }
                Spacer(minLength: 0)
                Button {
                    center.actions?.panelQuit()
                } label: {
                    Text("退出 AgentBar")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .systemRed).opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func smallButton(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 11.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
