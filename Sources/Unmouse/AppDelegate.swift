import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let switcher = SwitcherController()
    private let hints = HintController()
    private let scroller = ScrollController()
    private let settingsModel = SettingsModel()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var openMenuItem: NSMenuItem?
    private var hintMenuItem: NSMenuItem?
    private var scrollMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        buildMainMenu()
        buildStatusItem()

        // 문제 진단용: `defaults read app.unmouse.Unmouse lastLaunchStatus`
        UserDefaults.standard.set("accessibility=\(AXIsProcessTrusted()) screenCapture=\(CGPreflightScreenCaptureAccess())", forKey: "lastLaunchStatus")
        switcher.prepare()
        switcher.onOpenSettings = { [weak self] in self?.showSettings() }
        settingsModel.onClose = { [weak self] in self?.settingsWindow?.close() }
        settingsModel.onTryIt = { [weak self] in
            self?.settingsWindow?.close()
            self?.switcher.show()
        }

        hints.onNeedPermission = { [weak self] in self?.showSettings() }
        scroller.onNeedPermission = { [weak self] in self?.showSettings() }
        // 세 모드는 한 번에 하나만 켜진다.
        HotKeyCenter.shared.handlers[.switcher] = { [weak self] in
            self?.hints.close()
            self?.scroller.close()
            self?.switcher.toggle()
        }
        HotKeyCenter.shared.handlers[.hints] = { [weak self] in
            guard let self, !self.switcher.isOpen else { return }
            self.scroller.close()
            self.hints.toggle()
        }
        HotKeyCenter.shared.handlers[.scroll] = { [weak self] in
            guard let self, !self.switcher.isOpen else { return }
            self.hints.close()
            self.scroller.toggle()
        }
        var registered = true
        for slot in HotKeySlot.allCases where !HotKeyCenter.shared.register(Shortcut.load(slot), for: slot) {
            registered = false
            settingsModel.shortcutError = "\(Shortcut.load(slot).display) 단축키를 등록하지 못했습니다. 다른 단축키를 지정해 주세요."
        }

        // 처음 실행했거나 권한이 없으면 설정 창으로 안내한다.
        if !AXIsProcessTrusted() || !registered {
            showSettings()
        }
    }

    /// 이미 실행 중일 때 Spotlight 등에서 다시 열면 설정 창을 보여 준다 (마우스 없이 설정에 들어가는 방법).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: 메뉴 막대

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Unmouse")

        let menu = NSMenu()
        let open = NSMenuItem(title: "윈도우 선택기 열기", action: #selector(openSwitcher), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        openMenuItem = open
        let hint = NSMenuItem(title: "클릭 힌트 표시", action: #selector(showHints), keyEquivalent: "")
        hint.target = self
        menu.addItem(hint)
        hintMenuItem = hint
        let scroll = NSMenuItem(title: "키보드 스크롤 모드", action: #selector(startScrolling), keyEquivalent: "")
        scroll.target = self
        menu.addItem(scroll)
        scrollMenuItem = scroll
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "설정…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Unmouse 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// 설정 창에서 ⌘W / ⌘Q / 복사·붙여넣기가 동작하려면 메인 메뉴가 있어야 한다.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Unmouse 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func openSwitcher() {
        switcher.show()
    }

    @objc private func showHints() {
        // 메뉴가 닫히고 원래 앱이 다시 앞에 온 뒤에 훑는다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.hints.toggle() }
    }

    @objc private func startScrolling() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.scroller.toggle() }
    }

    // MARK: 설정 창

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settingsModel)))
            window.title = "Unmouse 설정"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        openMenuItem?.title = "윈도우 선택기 열기    \(Shortcut.load(.switcher).display)"
        hintMenuItem?.title = "클릭 힌트 표시    \(Shortcut.load(.hints).display)"
        scrollMenuItem?.title = "키보드 스크롤 모드    \(Shortcut.load(.scroll).display)"
    }
}
