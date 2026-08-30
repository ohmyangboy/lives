// 安装窗口背景源文件。修改后运行：swift scripts/render-dmg-background.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("src-tauri/tauri.conf.json"))) as! [String: Any]
let bundle = configuration["bundle"] as! [String: Any]
let macOS = bundle["macOS"] as! [String: Any]
let dmg = macOS["dmg"] as! [String: Any]
let window = dmg["windowSize"] as! [String: Int]
let width = CGFloat(window["width"]!)
let height = CGFloat(window["height"]! - 28) // 无工具栏 Finder 窗口的内容区
let scale: CGFloat = 2
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}
let ink = color(42, 39, 32)
let secondary = color(108, 103, 92)
let amber = color(220, 154, 33)
color(250, 248, 242).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

func text(_ value: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, foreground: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: foreground,
        .paragraphStyle: paragraph,
    ]
    (value as NSString).draw(in: NSRect(x: 24, y: height - top - size * 1.6, width: width - 48, height: size * 1.6), withAttributes: attributes)
}

text("安装 Lives", top: 30, size: 29, weight: .semibold, foreground: ink)
text("将 Lives 拖入右侧的「应用程序」文件夹", top: 79, size: 15, weight: .regular, foreground: secondary)

let arrow = NSBezierPath()
let arrowY = height - 190
arrow.move(to: NSPoint(x: width / 2 - 25, y: arrowY))
arrow.line(to: NSPoint(x: width / 2 + 25, y: arrowY))
arrow.move(to: NSPoint(x: width / 2 + 14, y: arrowY + 11))
arrow.line(to: NSPoint(x: width / 2 + 25, y: arrowY))
arrow.line(to: NSPoint(x: width / 2 + 14, y: arrowY - 11))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
amber.setStroke()
arrow.stroke()

let notice = NSBezierPath(roundedRect: NSRect(x: 32, y: height - 382, width: width - 64, height: 79), xRadius: 14, yRadius: 14)
color(242, 237, 224).setFill()
notice.fill()
text("安装后，请从「应用程序」打开 Lives", top: 316, size: 15, weight: .semibold, foreground: ink)
text("请勿在此安装窗口内直接运行，以确保照片授权正确。", top: 347, size: 12, weight: .regular, foreground: secondary)

NSGraphicsContext.restoreGraphicsState()
let output = root.appendingPathComponent("src-tauri/\(dmg["background"] as! String)")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("已生成安装背景：\(output.path)")
