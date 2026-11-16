import AppKit
import SwiftUI

let app = NSApplication.shared

MainActor.assumeIsolated {
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
        // 개발용: 화면에 띄우지 않고 UI 를 PNG 로 렌더링한다.  Unmouse --snapshot <디렉터리>
        Snapshot.run(outputDirectory: CommandLine.arguments[index + 1])
    } else if let index = CommandLine.arguments.firstIndex(of: "--demo"), CommandLine.arguments.count > index + 1 {
        // 개발용: 목업 윈도우로 README 용 예시 화면을 만든다.  Unmouse --demo <디렉터리>
        Demo.run(outputDirectory: CommandLine.arguments[index + 1])
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
    } else if let index = CommandLine.arguments.firstIndex(of: "--test-desktop"), CommandLine.arguments.count > index + 1 {
        // 개발용: 데스크탑 전환이 실제로 일어나는지 확인하고 원래 데스크탑으로 돌아온다.
        //   Unmouse --test-desktop <디렉터리> [direct]
        //   기본: 사람이 ⌃⌘→ 를 누른 것처럼 키를 보내 실행 중인 Unmouse 의 단축키를 거친다 (수정 키를 누른 채).
        //   direct: DesktopSwitcher 를 바로 호출한다.
        let directory = CommandLine.arguments[index + 1]
        let direct = CommandLine.arguments.contains("direct")
        let cid = CGSMainConnectionID()
        var lines = ["trusted=\(AXIsProcessTrusted()) postAccess=\(CGPreflightPostEventAccess()) mode=\(direct ? "direct" : "hotkey")"]
        func hold(_ keyCode: Int, _ flags: CGEventFlags) {
            let source = CGEventSource(stateID: .hidSystemState)
            let modifiers: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (55, .maskCommand)] // ⌃, ⌘
            var held: CGEventFlags = []
            for (code, flag) in modifiers {
                held.insert(flag)
                let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true); e?.flags = held
                e?.post(tap: .cghidEventTap); usleep(20_000)
            }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
                e?.flags = held.union(flags); e?.post(tap: .cghidEventTap); usleep(20_000)
            }
            usleep(300_000) // 수정 키를 누르고 있는 동안 Unmouse 가 처리하게 둔다
            for (code, flag) in modifiers.reversed() {
                held.remove(flag)
                let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false); e?.flags = held
                e?.post(tap: .cghidEventTap); usleep(20_000)
            }
        }
        func step(_ direction: DesktopSwitcher.Direction) {
            let before = CGSGetActiveSpace(cid)
            if direct { DesktopSwitcher.move(direction) } else { hold(direction == .left ? 123 : 124, .maskSecondaryFn) }
            usleep(1_200_000)
            lines.append("\(direction): \(before) -> \(CGSGetActiveSpace(cid))")
        }
        step(.right)
        step(.left)
        try? lines.joined(separator: "\n").write(toFile: "\(directory)/desktop.txt", atomically: true, encoding: .utf8)
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
        guard let rep = bitmap(of: view, size: size) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    static func image(of view: some View, size: CGSize) -> CGImage? {
        bitmap(of: view, size: size)?.cgImage
    }

    private static func bitmap(of view: some View, size: CGSize) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .darkGray
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }
}
