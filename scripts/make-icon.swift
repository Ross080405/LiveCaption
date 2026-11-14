// 生成应用图标：swift scripts/make-icon.swift
// 输出 Resources/AppIcon.icns（已提交到仓库，改了设计才需要重新运行）。
// 设计：深色圆角方块，上面是一段声波（正在听），下面是两行字幕（上一句淡、当前句亮）。
import AppKit

let canvas: CGFloat = 1024

func draw(in ctx: CGContext) {
    let space = CGColorSpaceCreateDeviceRGB()
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                                CGFloat(hex & 0xff) / 255, alpha])!
    }
    func gradient(_ colors: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    }
    func pill(centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height),
               cornerWidth: min(width, height) / 2, cornerHeight: min(width, height) / 2, transform: nil)
    }

    // macOS 图标规范：1024 画布里放 824 的圆角方块，四周留白给阴影
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // 阴影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1c1c1f))
    ctx.fillPath()
    ctx.restoreGState()

    // 底色：上浅下深的炭黑
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x3a3a41), color(0x17171a)]),
                           start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // 声波背后的一团暖光
    ctx.drawRadialGradient(gradient([color(0xff5a47, 0.28), color(0xff5a47, 0)]),
                           startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 640), endRadius: 420, options: [])
    ctx.restoreGState()

    // 顶部一圈细高光
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xffffff, 0.22), color(0xffffff, 0.02)]),
                           start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
    ctx.restoreGState()
    ctx.setLineWidth(6)

    // 声波：7 根圆头竖条
    let heights: [CGFloat] = [96, 200, 310, 230, 340, 170, 86]
    let barWidth: CGFloat = 46, gap: CGFloat = 30
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let waveY: CGFloat = 640
    ctx.saveGState()
    for (i, h) in heights.enumerated() {
        let x = 512 - total / 2 + CGFloat(i) * (barWidth + gap) + barWidth / 2
        ctx.addPath(pill(centerX: x, centerY: waveY, width: barWidth, height: h))
    }
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xff8a5c), color(0xff4d4d)]),
                           start: CGPoint(x: 0, y: waveY + 170), end: CGPoint(x: 0, y: waveY - 170), options: [])
    ctx.restoreGState()

    // 字幕：上一句（淡、短），当前句（亮、长）
    ctx.addPath(pill(centerX: 512, centerY: 366, width: 330, height: 46))
    ctx.setFillColor(color(0xffffff, 0.38))
    ctx.fillPath()
    ctx.addPath(pill(centerX: 512, centerY: 268, width: 560, height: 72))
    ctx.setFillColor(color(0xffffff, 0.96))
    ctx.fillPath()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    draw(in: ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LiveCaption-\(UUID().uuidString)/AppIcon.iconset")
let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    try png(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let output = resources.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil 失败") }

// 可选：再导出一张 PNG 预览  swift scripts/make-icon.swift /path/preview.png
if CommandLine.arguments.count > 1 {
    try png(pixels: 512).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
try? FileManager.default.removeItem(at: iconset.deletingLastPathComponent())
print("✓ \(output.path)")
