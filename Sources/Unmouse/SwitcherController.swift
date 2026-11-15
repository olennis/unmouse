import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 키 입력을 받을 수 있는 테두리 없는 전체 화면 패널.
/// nonactivating 이라서 Unmouse 가 앞으로 나오지 않고, 닫으면 원래 앱이 그대로 포커스를 유지한다.
final class SwitcherPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var keyUpHandler: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        if event.type == .keyUp { keyUpHandler?(event) }
        super.sendEvent(event)
    }
}

@MainActor
final class SwitcherController: NSObject, NSWindowDelegate {
    let model = SwitcherModel()
    var onOpenSettings: (() -> Void)?

    private enum Phase { case closed, loading, open, closing }

    private var panel: SwitcherPanel?
    private var phase = Phase.closed
    var isOpen: Bool { phase != .closed }

    private static let expandAnimation = Animation.spring(response: 0.3, dampingFraction: 0.9)
    private static let collapseDuration = 0.2

    /// 단축키를 눌렀을 때: 닫혀 있으면 열고, 열려 있으면 다음 윈도우로 이동한다.
    func toggle() {
        switch phase {
        case .open: model.moveSelection(by: 1)
        case .closed: show()
        case .loading, .closing: break
        }
    }

    static let thumbnailPixels: CGFloat = 1200

    // MARK: 미리 준비

    private var refreshing = false
    private var refreshPending = false
    private var timer: Timer?

    /// 단축키를 누른 순간 할 일이 없도록, 패널과 윈도우 목록·미리보기를 평소에 준비해 둔다.
    func prepare() {
        panel = makePanel()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh(captureThumbnails: true) }
            }
        }
        // 새 윈도우·제목 변경 등 알림이 오지 않는 변화는 주기적으로 따라잡는다 (목록만, 캡처는 안 함).
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(captureThumbnails: false) }
        }
        scheduleRefresh(captureThumbnails: true)
    }

    private func scheduleRefresh(captureThumbnails: Bool, delay: TimeInterval = 0.3) {
        guard phase == .closed else { return }
        if refreshing {
            refreshPending = refreshPending || captureThumbnails
            return
        }
        refreshing = true
        // 앱 전환 직후에는 새 윈도우가 다 그려질 시간을 조금 준다.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            let windows = WindowCatalog.shared.refresh()
            Task { @MainActor in
                self.refreshing = false
                if captureThumbnails, self.phase == .closed {
                    self.model.prewarmThumbnails(for: windows, maxPixelSize: Self.thumbnailPixels)
                }
                if self.refreshPending {
                    self.refreshPending = false
                    self.scheduleRefresh(captureThumbnails: true)
                }
            }
        }
    }

    // MARK: 열기

    func show() {
        guard phase == .closed else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // 빠른 길: 준비해 둔 목록으로 같은 프레임에 바로 띄운다.
        if let quick = WindowCatalog.shared.quickList() {
            present(WindowCatalog.applyPreferences(quick), frontmostPID: frontmostPID)
        } else {
            phase = .loading
        }

        // 정확한 목록은 뒤에서 다시 모아, 달라진 게 있을 때만 반영한다. (AX 호출은 메인 스레드 밖에서)
        DispatchQueue.global(qos: .userInteractive).async {
            let windows = WindowCatalog.applyPreferences(WindowCatalog.shared.refresh())
            Task { @MainActor in
                switch self.phase {
                case .loading: self.present(windows, frontmostPID: frontmostPID)
                case .open: withAnimation(.snappy(duration: 0.25)) { self.model.update(windows) }
                case .closed, .closing: break
                }
            }
        }
    }

    private func present(_ windows: [WindowInfo], frontmostPID: pid_t?) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            phase = .closed
            return
        }
        // CoreGraphics 좌표(주 화면 왼쪽 위 원점)에서 이 화면의 원점
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        model.screenOrigin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
        let visible = screen.visibleFrame
        let safe = EdgeInsets(top: max(screen.frame.maxY - visible.maxY, screen.safeAreaInsets.top),
                              leading: visible.minX - screen.frame.minX,
                              bottom: visible.minY - screen.frame.minY,
                              trailing: screen.frame.maxX - visible.maxX)
        if model.safeInsets != safe { model.safeInsets = safe }
        model.contentRect = SwitcherInsets.contentRect(size: screen.frame.size, safe: safe)
        model.expanded = false
        model.raisedID = nil
        model.load(windows, frontmostPID: frontmostPID)
        model.startLiveThumbnails(maxPixelSize: Self.thumbnailPixels)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        // 접힌 상태(카드가 실제 윈도우와 같은 자리·크기)를 확실히 먼저 그려 둔다.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        phase = .open

        // 카드가 실제 윈도우 위에 겹쳐진 상태에서 곧바로 Mission Control 배치로 펼쳐진다.
        // (접힌 상태가 먼저 한 번 그려져야 그 자리에서 출발하는 애니메이션이 된다)
        DispatchQueue.main.async {
            withAnimation(Self.expandAnimation) { self.model.expanded = true }
        }
    }

    /// 카드를 실제 윈도우 자리로 되돌리는 애니메이션 후 패널을 내린다.
    func close(activating window: WindowInfo? = nil) {
        guard phase == .open else { return }
        phase = .closing
        model.stopLiveThumbnails()
        if let window {
            model.selectedID = window.id
            model.raisedID = window.id
            // 애니메이션이 끝날 때 실제 윈도우가 이미 맨 앞에 와 있도록 먼저 전환한다.
            DispatchQueue.global(qos: .userInteractive).async { WindowFocuser.focus(window) }
        }
        withAnimation(.easeInOut(duration: Self.collapseDuration)) { model.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDuration + 0.02) {
            self.panel?.orderOut(nil)
            self.model.endSearch()
            self.phase = .closed
            self.scheduleRefresh(captureThumbnails: true, delay: 0.4) // 전환 결과를 다음 번을 위해 찍어 둔다
        }
    }

    private func activate(_ window: WindowInfo) {
        close(activating: window)
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(contentRect: .zero,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        // Dock·메뉴 막대 바로 아래: Mission Control 처럼 둘은 그대로 보이고 일반 윈도우만 덮는다.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        let view = SwitcherView(model: model,
                                onActivate: { [weak self] in self?.activate($0) },
                                onClose: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    // 다른 앱을 클릭하는 등 포커스를 잃으면 닫는다.
    func windowDidResignKey(_ notification: Notification) {
        close() // 이미 닫히는 중이면 무시된다
    }

    // MARK: 키 처리

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)

        switch code {
        case kVK_Escape:
            if model.isSearching { model.endSearch() } else { close() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let window = model.selected { activate(window) }
            return true
        case kVK_LeftArrow:
            model.moveSelection(by: -1, wrap: false)
            return true
        case kVK_RightArrow:
            model.moveSelection(by: 1, wrap: false)
            return true
        case kVK_UpArrow:
            model.moveVertically(-1)
            return true
        case kVK_DownArrow:
            model.moveVertically(1)
            return true
        case kVK_Tab:
            model.moveSelection(by: flags.contains(.shift) ? -1 : 1)
            return true
        case kVK_ANSI_Comma where flags == .command:
            close()
            onOpenSettings?()
            return true
        default:
            break
        }

        // 검색 중에는 나머지 키를 텍스트 필드로 보낸다.
        if model.isSearching { return false }

        if flags.isEmpty || flags == .shift {
            if code == kVK_Space {
                if let window = model.selected { activate(window) }
            } else if code == kVK_ANSI_Slash {
                model.beginSearch()
            } else if let window = model.window(forHintKeyCode: event.keyCode) {
                activate(window)
            }
        }
        return true
    }
}

enum Preferences {
    static let includeMinimized = "includeMinimized"
    static let includeOtherSpaces = "includeOtherSpaces"
    static let showMenuBarIcon = "showMenuBarIcon"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [includeMinimized: true, includeOtherSpaces: true, showMenuBarIcon: true])
    }
}

extension UserDefaults {
    /// KVO 로 지켜보기 위한 속성. 이름이 Preferences.showMenuBarIcon 키와 같아야 한다.
    @objc dynamic var showMenuBarIcon: Bool { bool(forKey: Preferences.showMenuBarIcon) }
}
