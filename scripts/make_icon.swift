import AppKit

// 生成 1024×1024 的 App 图标：深色圆角方块 + 白色闪电 + 底部一条「触控栏」上的三颗状态点
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let S = CGFloat(px)
let inset: CGFloat = S * 0.098          // 系统图标的留白比例
let body = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2235, yRadius: body.height * 0.2235)

// 底：上深下更深的冷灰蓝
let bg = NSGradient(colors: [
    NSColor(srgbRed: 0.169, green: 0.184, blue: 0.216, alpha: 1),
    NSColor(srgbRed: 0.063, green: 0.071, blue: 0.090, alpha: 1)
])!
bg.draw(in: squircle, angle: -90)

// 顶部一道很淡的高光，避免整块死黑
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
let sheen = NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0.0)])!
sheen.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 边框
NSColor(white: 1, alpha: 0.12).setStroke()
squircle.lineWidth = S * 0.006
squircle.stroke()

// 底部「触控栏」：一条圆角槽 + 三颗状态点（蓝 / 琥珀 / 青绿）
let slotH = S * 0.125
let slotW = body.width * 0.60
let slot = NSRect(x: body.midX - slotW / 2, y: body.minY + S * 0.085,
                  width: slotW, height: slotH)
let slotPath = NSBezierPath(roundedRect: slot, xRadius: slotH / 2, yRadius: slotH / 2)
NSColor(white: 1, alpha: 0.07).setFill()
slotPath.fill()
NSColor(white: 1, alpha: 0.10).setStroke()
slotPath.lineWidth = S * 0.004
slotPath.stroke()

let dots: [NSColor] = [
    NSColor(srgbRed: 0.29, green: 0.62, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.76, blue: 0.29, alpha: 1),
    NSColor(srgbRed: 0.24, green: 0.82, blue: 0.68, alpha: 1)
]
let dotR = slotH * 0.19
let gap = slotW * 0.16
let span = gap * CGFloat(dots.count - 1)
for (i, color) in dots.enumerated() {
    let center = NSPoint(x: slot.midX - span / 2 + CGFloat(i) * gap, y: slot.midY)
    let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotR, y: center.y - dotR,
                                          width: dotR * 2, height: dotR * 2))
    color.setFill()
    dot.fill()
}

// 闪电：手绘多边形，居中偏上
func bolt(center: NSPoint, height: CGFloat) -> NSBezierPath {
    let pts: [(CGFloat, CGFloat)] = [
        (0.62, 1.00), (0.20, 0.52), (0.45, 0.52), (0.36, 0.00),
        (0.80, 0.50), (0.54, 0.50)
    ]
    let w: CGFloat = 0.50
    let p = NSBezierPath()
    for (i, pt) in pts.enumerated() {
        let x = center.x + (pt.0 - 0.5) / 0.42 * w * height / 2
        let y = center.y + (pt.1 - 0.5) * height
        i == 0 ? p.move(to: NSPoint(x: x, y: y)) : p.line(to: NSPoint(x: x, y: y))
    }
    p.close()
    return p
}

let boltCenter = NSPoint(x: body.midX, y: body.minY + body.height * 0.635)
let boltPath = bolt(center: boltCenter, height: body.height * 0.42)
let boltGrad = NSGradient(colors: [NSColor(white: 1.0, alpha: 1), NSColor(white: 0.88, alpha: 1)])!
boltGrad.draw(in: boltPath, angle: -90)

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon-1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
