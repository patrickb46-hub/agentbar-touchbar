import AppKit
import SwiftUI

/// 面板窗口：一块**正常**的 macOS 窗口 —— 有标题栏、红黄绿三个按钮、
/// 能拖动、能最小化、能缩放，关掉后 App 继续留在菜单栏。
final class PanelWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let center: ControlCenter

    /// 窗口默认大小（可以拖大拖小，有下限）
    static let defaultSize = NSSize(width: 400, height: 580)
    static let minSize = NSSize(width: 360, height: 460)

    init(center: ControlCenter) {
        self.center = center
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func makeWindow() -> NSWindow {
        if let window { return window }

        let hosting = NSHostingController(rootView: PanelView(center: center))
        let w = NSWindow(contentViewController: hosting)
        w.title = "AgentBar"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(Self.defaultSize)
        w.minSize = Self.minSize
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.tabbingMode = .disallowed
        // 记住上次的位置，下次打开还在原地
        w.setFrameAutosaveName("AgentBarPanelWindow")
        if w.frame.origin == .zero { w.center() }
        Log.write("窗口样式：可移动=\(w.isMovable) 可关闭=\(w.styleMask.contains(.closable)) 可最小化=\(w.styleMask.contains(.miniaturizable)) 可缩放=\(w.styleMask.contains(.resizable)) 标题=\(w.title)")
        window = w
        return w
    }

    func show() {
        let w = makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        Log.write("面板窗口已显示：\(Int(w.frame.width))x\(Int(w.frame.height)) @ (\(Int(w.frame.minX)),\(Int(w.frame.minY)))")
    }

    func toggle() {
        if isVisible, window?.isKeyWindow == true {
            window?.orderOut(nil)
            Log.write("面板窗口已收起")
        } else if isVisible, window?.isKeyWindow == false {
            // 已经开着但不在前台：拉到最前，而不是关掉（符合直觉）
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            show()
        }
    }

    func close() {
        window?.close()
    }
}
