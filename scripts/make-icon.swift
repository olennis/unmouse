// 앱 아이콘 생성: swift scripts/make-icon.swift <출력 .iconset 디렉터리>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1),
                        NSColor(red: 0.20, green: 0.30, blue: 0.92, alpha: 1)])!.draw(in: squircle, angle: -90)

    // 윈도우 타일 3개 (Mission Control 느낌) + 선택된 타일 하나
    let tiles: [(CGRect, Bool)] = [
        (CGRect(x: 0.20, y: 0.52, width: 0.27, height: 0.24), false),
        (CGRect(x: 0.53, y: 0.52, width: 0.27, height: 0.24), true),
        (CGRect(x: 0.20, y: 0.24, width: 0.60, height: 0.22), false),
    ]
    for (t, selected) in tiles {
        let r = CGRect(x: t.minX * s, y: t.minY * s, width: t.width * s, height: t.height * s)
        let path = NSBezierPath(roundedRect: r, xRadius: s * 0.04, yRadius: s * 0.04)
        NSColor.white.withAlphaComponent(selected ? 1.0 : 0.45).setFill()
        path.fill()
    }
    // 선택된 타일 위의 키 힌트 글자
    let font = NSFont.systemFont(ofSize: s * 0.16, weight: .heavy)
    let text = NSAttributedString(string: "U", attributes: [.font: font, .foregroundColor: NSColor(red: 0.20, green: 0.32, blue: 0.92, alpha: 1)])
    let size = text.size()
    let tile = tiles[1].0
    text.draw(at: CGPoint(x: (tile.midX * s) - size.width / 2, y: (tile.midY * s) - size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
