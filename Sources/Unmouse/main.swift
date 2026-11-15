import AppKit
import SwiftUI

let app = NSApplication.shared

MainActor.assumeIsolated {
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
        // 개발용: 화면에 띄우지 않고 UI 를 PNG 로 렌더링한다.  Unmouse --snapshot <디렉터리>
        Snapshot.run(outputDirectory: CommandLine.arguments[index + 1])
    } else if let index = CommandLine.arguments.firstIndex(of: "--dump-hints"), CommandLine.arguments.count > index + 1 {
        // 개발용: 맨 앞 앱(또는 --bundle 로 지정한 앱)의 클릭 힌트를 계산해 기록한다.
        let directory = CommandLine.arguments[index + 1]
        var target = NSWorkspace.shared.frontmostApplication
        if let b = CommandLine.arguments.firstIndex(of: "--bundle"), CommandLine.arguments.count > b + 1 {
            target = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[b + 1]).first
        }
        var lines = ["trusted=\(AXIsProcessTrusted()) app=\(target?.localizedName ?? "nil")"]
        if let target {
            let start = Date()
            let result = HintScanner.scan(app: target)
            lines.append("elapsed=\(Int(Date().timeIntervalSince(start) * 1000))ms targets=\(result.frames.count) window=\(String(describing: result.windowFrame))")
            let scroll = ScrollScanner.areas(app: target)
            lines.append("scrollAreas=\(scroll.areas)")
            let model = HintModel()
            let labels = HintScanner.labels(count: result.frames.count)
            let sorted = result.frames.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            model.targets = zip(sorted, labels).enumerated().map { HintTarget(id: $0, frame: $1.0, clickPoint: .zero, label: $1.1) }
            for t in model.targets.prefix(40) { lines.append("\(t.label) \(t.frame)") }
            let size = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
            Snapshot.render(HintOverlay(model: model), size: size, to: "\(directory)/hints.png")
        }
        try? lines.joined(separator: "\n").write(toFile: "\(directory)/hints.txt", atomically: true, encoding: .utf8)
        exit(0)
    } else if let index = CommandLine.arguments.firstIndex(of: "--dump-wallpaper"), CommandLine.arguments.count > index + 1 {
        let directory = CommandLine.arguments[index + 1]
        Task {
            await Wallpaper.dump(to: directory)
            exit(0)
        }
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
enum Snapshot {
    static func run(outputDirectory: String) {
        Preferences.registerDefaults()
        let windows = WindowCatalog.shared.list(includeMinimized: true, includeOtherSpaces: true)
        print("windows: \(windows.count)")
        for w in windows { print(" -", w.id, w.appName, "|", w.title, "|", w.location) }

        let model = SwitcherModel()
        model.safeInsets = EdgeInsets(top: 30, leading: 0, bottom: 90, trailing: 0)
        model.contentRect = SwitcherInsets.contentRect(size: CGSize(width: 1728, height: 1117), safe: model.safeInsets)
        model.load(windows, frontmostPID: windows.first?.pid)
        model.expanded = true
        render(SwitcherView(model: model), size: CGSize(width: 1728, height: 1117), to: "\(outputDirectory)/switcher.png")

        model.beginSearch()
        model.query = "s"
        render(SwitcherView(model: model), size: CGSize(width: 1728, height: 1117), to: "\(outputDirectory)/search.png")

        render(SettingsView(model: SettingsModel()), size: CGSize(width: 560, height: 760), to: "\(outputDirectory)/settings.png")
    }

    static func render(_ view: some View, size: CGSize, to path: String) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .darkGray
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
