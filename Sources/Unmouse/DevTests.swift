import AppKit
import ApplicationServices

/// 개발용: 사람이 키를 누른 것처럼 이벤트를 보내 실행 중인 Unmouse 를 거치는 시나리오를 돌리고 결과를 기록한다.
/// 키 이벤트를 보내려면 손쉬운 사용 권한이 필요하므로 앱 번들로 실행한다:
///   open -n -W /Applications/Unmouse.app --args --test-desktop <디렉터리> [시나리오]
///
/// 시나리오 (모두 오른쪽 데스크탑으로 갔다가 원래 데스크탑으로 돌아온다)
///   hotkey  ⌃⌘→ 만 누른다 (기본)
///   direct  DesktopSwitcher 를 바로 호출한다
///   open    ⌥Tab 으로 선택기를 연 채로 ⌃⌘→
///   esc     ⌥Tab → esc 로 닫은 뒤 ⌃⌘→
///   select  ⌥Tab → Space 로 윈도우를 고른 뒤 ⌃⌘→
enum DevTests {
    private static let control: (CGKeyCode, CGEventFlags) = (59, .maskControl)
    private static let command: (CGKeyCode, CGEventFlags) = (55, .maskCommand)
    private static let option: (CGKeyCode, CGEventFlags) = (58, .maskAlternate)

    @MainActor
    static func runDesktop(directory: String, scenario: String) {
        let cid = CGSMainConnectionID()
        var lines = ["trusted=\(AXIsProcessTrusted()) postAccess=\(CGPreflightPostEventAccess()) scenario=\(scenario)"]
        func log(_ label: String) { lines.append("\(label): \(state(cid))") }

        log("start")
        switch scenario {
        case "open":
            press(48, holding: [option]); wait(0.8)    // ⌥Tab
            log("switcher open")
        case "esc":
            press(48, holding: [option]); wait(0.8)
            press(53); wait(0.6)                         // esc
            log("switcher closed")
        case "select":
            press(48, holding: [option]); wait(0.8)
            press(49); wait(0.8)                         // Space
            log("window selected")
        default: break
        }

        if scenario == "fast" {
            // 사용자가 보고한 순서: ⌥Tab 으로 연 채로 바로 ⌃⌘→. 넘어가는 동안 여러 시점의 포커스와 화면을 남긴다.
            press(48, holding: [option]); wait(0.5)
            log("switcher open")
            let start = Date()
            DispatchQueue.global().async { press(124, holding: [control, command], extra: .maskSecondaryFn) }
            for (i, t) in [0.1, 0.25, 0.4, 0.6, 0.9, 1.5, 3.0].enumerated() {
                wait(max(0, t - Date().timeIntervalSince(start)))
                let shot = "\(directory)/fast-\(i).png"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-t", "png", shot]
                try? p.run()
                log(String(format: "t=%.2fs", Date().timeIntervalSince(start)))
            }
            wait(0.5)
            DesktopSwitcher.move(.left); wait(1.5)
            log("back")
            try? lines.joined(separator: "\n").write(toFile: "\(directory)/desktop.txt", atomically: true, encoding: .utf8)
            return
        }

        if scenario == "swipe" {
            // 트랙패드 스와이프처럼 Unmouse 를 거치지 않고 데스크탑이 바뀌는 경우: 선택기를 연 채로 시스템 ⌃→
            press(48, holding: [option]); wait(0.8)
            log("switcher open")
            press(124, holding: [control], extra: .maskSecondaryFn); wait(1.5)
            log("after system ⌃→")
            press(49); wait(1.0)                          // 열려 있다면 Space 로 고른다
            log("after Space")
            press(53); wait(0.5)                          // 혹시 남아 있으면 닫기
            DesktopSwitcher.move(.left); wait(1.5)
            log("back")
            try? lines.joined(separator: "\n").write(toFile: "\(directory)/desktop.txt", atomically: true, encoding: .utf8)
            return
        }

        if scenario == "direct" { DesktopSwitcher.move(.right) } else { press(124, holding: [control, command], extra: .maskSecondaryFn) }
        wait(1.5)
        log("after ⌃⌘→")

        if scenario == "there" {
            // 옮겨 간 데스크탑에서 ⌥Tab 을 열고 바로 고른다 (Space).
            press(48, holding: [option]); wait(0.8)
            log("switcher open there")
            press(49); wait(1.0)
            log("selected there")
        }

        if scenario == "direct" { DesktopSwitcher.move(.left) } else { press(123, holding: [control, command], extra: .maskSecondaryFn) }
        wait(1.5)
        log("after ⌃⌘←")
        try? lines.joined(separator: "\n").write(toFile: "\(directory)/desktop.txt", atomically: true, encoding: .utf8)
    }

    /// 활성 Space, 키 입력을 받는 앱·윈도우와 그 윈도우가 속한 Space
    private static func state(_ cid: Int32) -> String {
        let active = CGSGetActiveSpace(cid)
        let system = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = system.attribute(kAXFocusedApplicationAttribute) else {
            return "space=\(active) focusedApp=nil"
        }
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        guard let window: AXUIElement = app.attribute(kAXFocusedWindowAttribute) else {
            return "space=\(active) focusedApp=\(name) focusedWindow=nil"
        }
        let title: String = window.attribute(kAXTitleAttribute) ?? ""
        let spaces = window.windowID.map { SpaceMap.spaces(of: $0) } ?? []
        return "space=\(active) focusedApp=\(name) window=\"\(title.prefix(40))\" windowSpaces=\(spaces)"
    }

    private static func wait(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

    /// 수정 키를 차례로 누르고, 키를 친 뒤, 잠시 유지했다가 놓는다 (사람이 누르는 순서 그대로).
    private static func press(_ keyCode: CGKeyCode, holding modifiers: [(CGKeyCode, CGEventFlags)] = [],
                              extra: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        var held: CGEventFlags = []
        for (code, flag) in modifiers { held.insert(flag); post(code, true, held) }
        post(keyCode, true, held.union(extra))
        post(keyCode, false, held.union(extra))
        if !modifiers.isEmpty { usleep(300_000) } // 수정 키를 누르고 있는 동안 Unmouse 가 처리하게 둔다
        for (code, flag) in modifiers.reversed() { held.remove(flag); post(code, false, held) }
    }
}
