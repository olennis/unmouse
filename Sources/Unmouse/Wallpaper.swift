import AppKit
import ScreenCaptureKit

/// Mission Control 배경처럼 쓰기 위해, 화면에 실제로 그려져 있는 바탕화면을 그대로 찍는다.
/// (동적 배경·Space 별 배경에서도 "지금 보이는 그대로"를 얻기 위해 파일을 읽지 않고 바탕화면 윈도우를 캡처한다.)
enum Wallpaper {
    /// screenFrame: CoreGraphics 좌표(주 화면 왼쪽 위 원점)의 화면 영역
    static func capture(from content: SCShareableContent, screenFrame: CGRect, scale: CGFloat) async -> CGImage? {
        let candidates = content.windows.filter { window in
            window.windowLayer < 0
                && (window.title ?? "").hasPrefix("Wallpaper")
                && abs(window.frame.minX - screenFrame.minX) < 2 && abs(window.frame.minY - screenFrame.minY) < 2
                && abs(window.frame.width - screenFrame.width) < 2 && abs(window.frame.height - screenFrame.height) < 2
        }
        guard let window = candidates.first(where: \.isOnScreen) ?? candidates.first else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    }

    /// 키 입력을 받고 있는 화면의 (CoreGraphics 좌표 영역, 픽셀 배율)
    @MainActor
    static func mainScreen() -> (frame: CGRect, scale: CGFloat)? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                           width: screen.frame.width, height: screen.frame.height)
        return (frame, screen.backingScaleFactor)
    }

    /// 개발용: Unmouse --dump-wallpaper <디렉터리>
    static func dump(to directory: String) async {
        var lines: [String] = ["preflight=\(CGPreflightScreenCaptureAccess())"]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            for w in content.windows where w.windowLayer < 0 {
                lines.append("\(w.windowID) layer=\(w.windowLayer) on=\(w.isOnScreen) app=\(w.owningApplication?.bundleIdentifier ?? "?") title=\(w.title ?? "nil") frame=\(w.frame)")
            }
            let screen = NSScreen.main!
            let primaryHeight = NSScreen.screens.first!.frame.height
            let frame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
            lines.append("screen=\(frame) scale=\(screen.backingScaleFactor)")
            if let image = await capture(from: content, screenFrame: frame, scale: 0.5) {
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/wallpaper.png"))
                lines.append("captured \(image.width)x\(image.height)")
            } else {
                lines.append("capture returned nil")
            }
        } catch {
            lines.append("error: \(error)")
        }
        try? lines.joined(separator: "\n").write(toFile: "\(directory)/wallpaper.txt", atomically: true, encoding: .utf8)
    }
}
