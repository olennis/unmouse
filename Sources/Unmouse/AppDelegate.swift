import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let switcher = SwitcherController()
    private let hints = HintController()
    private let scroller = ScrollController()
    private let settingsModel = SettingsModel()
    private var statusItem: NSStatusItem?
    /// 마지막으로 적용한 아이콘 표시 여부. isVisible 을 다시 읽어 비교하면 재귀가 생긴다 (updateStatusItemVisibility 참고).
    private var appliedMenuBarIconVisible: Bool?
    private var menuBarIconObservation: NSKeyValueObservation?
    private var settingsWindow: NSWindow?
    private var openMenuItem: NSMenuItem?
    private var nextDisplayMenuItem: NSMenuItem?
    private var hintMenuItem: NSMenuItem?
    private var scrollMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        buildMainMenu()
        buildStatusItem()
        updateStatusItemVisibility()
        // 설정 창의 "메뉴 막대에 아이콘 표시" 를 바꾸면 바로 반영한다. 이 키만 지켜보고, 다음 런루프에서 적용한다.
        menuBarIconObservation = UserDefaults.standard.observe(\.showMenuBarIcon) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateStatusItemVisibility() }
        }

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
        HotKeyCenter.shared.handlers[.nextDisplay] = { [weak self] in
            self?.hints.close()
            self?.scroller.close()
            self?.switcher.showNextDisplay()
        }
        // 세 손가락 좌우 쓸기와 같은 데스크탑(Space) 전환. 떠 있는 모드는 닫고 넘어간다.
        for (slot, direction) in [(HotKeySlot.previousDesktop, DesktopSwitcher.Direction.left), (.nextDesktop, .right)] {
            HotKeyCenter.shared.handlers[slot] = { [weak self] in
                guard let self else { return }
                self.switcher.close()
                self.hints.close()
                self.scroller.close()
                if !DesktopSwitcher.move(direction) { self.showSettings() }
            }
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
            settingsModel.shortcutError = L10n.format("Could not register %@. Please choose another shortcut.", Shortcut.load(slot).display)
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
        let open = NSMenuItem(title: L10n.text("Open Window Switcher"), action: #selector(openSwitcher), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        openMenuItem = open
        let nextDisplay = NSMenuItem(title: L10n.text("Switch to Next Display"), action: #selector(openSwitcherOnNextDisplay), keyEquivalent: "")
        nextDisplay.target = self
        menu.addItem(nextDisplay)
        nextDisplayMenuItem = nextDisplay
        let hint = NSMenuItem(title: L10n.text("Show Click Hints"), action: #selector(showHints), keyEquivalent: "")
        hint.target = self
        menu.addItem(hint)
        hintMenuItem = hint
        let scroll = NSMenuItem(title: L10n.text("Keyboard Scroll Mode"), action: #selector(startScrolling), keyEquivalent: "")
        scroll.target = self
        menu.addItem(scroll)
        scrollMenuItem = scroll
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.text("Quit Unmouse"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// 아이콘을 숨겨도 앱은 계속 실행되고, Spotlight 에서 다시 실행하면 설정 창이 열린다.
    ///
    /// isVisible 을 바꾸면 AppKit 이 그 값을 UserDefaults 에 저장하면서 변경 알림을 동기로 보낸다.
    /// 그 시점엔 isVisible 이 아직 이전 값이라, isVisible 과 비교하면 같은 설정을 끝없이 반복하다 스택이 넘친다.
    /// 그래서 마지막으로 적용한 값과 비교하고, 바꾸기 전에 먼저 기록한다.
    private func updateStatusItemVisibility() {
        let visible = UserDefaults.standard.showMenuBarIcon
        guard let statusItem, appliedMenuBarIconVisible != visible else { return }
        appliedMenuBarIconVisible = visible
        statusItem.isVisible = visible
    }

    /// 설정 창에서 ⌘W / ⌘Q / 복사·붙여넣기가 동작하려면 메인 메뉴가 있어야 한다.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.text("Quit Unmouse"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.text("Window"))
        windowMenu.addItem(withTitle: L10n.text("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func openSwitcher() {
        switcher.show()
    }

    @objc private func openSwitcherOnNextDisplay() {
        switcher.showNextDisplay()
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
            window.title = L10n.text("Unmouse Settings")
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
        openMenuItem?.title = L10n.format("Open Window Switcher    %@", Shortcut.load(.switcher).display)
        nextDisplayMenuItem?.title = L10n.format("Switch to Next Display    %@", Shortcut.load(.nextDisplay).display)
        nextDisplayMenuItem?.isHidden = NSScreen.screens.count < 2
        hintMenuItem?.title = L10n.format("Show Click Hints    %@", Shortcut.load(.hints).display)
        scrollMenuItem?.title = L10n.format("Keyboard Scroll Mode    %@", Shortcut.load(.scroll).display)
    }
}
