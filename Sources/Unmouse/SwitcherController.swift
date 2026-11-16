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

    /// 전역 "다음 디스플레이" 단축키: 닫혀 있으면 다음 디스플레이에서 열고, 열려 있으면 다음 디스플레이로 옮긴다.
    func showNextDisplay() {
        switch phase {
        case .open: switchDisplay(by: 1)
        case .closed:
            pendingDisplayOffset = 1
            show()
        case .loading, .closing: break
        }
    }

    /// 다음에 열 때 처음 디스플레이에서 몇 칸 옮겨서 열지
    private var pendingDisplayOffset = 0

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
        // 열린 채로 데스크탑이 바뀌면(⌃⌘→, 트랙패드 스와이프) 그 데스크탑의 윈도우로 다시 채운다.
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.followSpaceChange() }
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
        let displays = SwitcherDisplay.all()
        let offset = pendingDisplayOffset
        pendingDisplayOffset = 0
        guard var display = Self.initialDisplay(windows, frontmostPID: frontmostPID, displays: displays) else {
            phase = .closed
            return
        }
        if offset != 0, let index = displays.firstIndex(of: display) {
            display = displays[((index + offset) % displays.count + displays.count) % displays.count]
        }
        guard let screen = Self.screen(for: display) else {
            phase = .closed
            return
        }
        applyGeometry(of: screen)
        model.expanded = false
        model.raisedID = nil
        // 다른 디스플레이로 열 때는 "지금 쓰던 윈도우 건너뛰기"가 필요 없으니 그 화면의 맨 앞 윈도우를 고른다.
        model.load(windows, frontmostPID: offset == 0 ? frontmostPID : nil, displays: displays, display: display)
        model.startLiveThumbnails(maxPixelSize: Self.thumbnailPixels)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        // 접힌 상태(카드가 실제 윈도우와 같은 자리·크기)를 확실히 먼저 그려 둔다.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        phase = .open
        openedSpace = Self.activeSpace()
        spaceChangedWhileOpen = false

        // 카드가 실제 윈도우 위에 겹쳐진 상태에서 곧바로 Mission Control 배치로 펼쳐진다.
        // (접힌 상태가 먼저 한 번 그려져야 그 자리에서 출발하는 애니메이션이 된다)
        DispatchQueue.main.async {
            withAnimation(Self.expandAnimation) { self.model.expanded = true }
        }
    }

    /// 처음 펼칠 디스플레이: 지금 쓰고 있는 윈도우가 있는 화면. 없으면 메뉴 막대가 활성인 화면.
    private static func initialDisplay(_ windows: [WindowInfo], frontmostPID: pid_t?,
                                       displays: [SwitcherDisplay]) -> SwitcherDisplay? {
        if let frontmostPID,
           let focused = windows.filter({ $0.pid == frontmostPID && $0.location == .visible }).min(by: { $0.rank < $1.rank }),
           let owner = SwitcherDisplay.owner(of: focused.frame, among: displays) {
            return owner
        }
        if let main = (NSScreen.main ?? NSScreen.screens.first)?.displayID,
           let display = displays.first(where: { $0.id == main }) {
            return display
        }
        return displays.first
    }

    private static func screen(for display: SwitcherDisplay) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == display.id }
    }

    /// 패널이 덮을 화면에 맞춰 여백과 카드 영역을 정한다.
    private func applyGeometry(of screen: NSScreen) {
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
        model.pageWidth = screen.frame.width
    }

    /// 열려 있는 선택기를 다음(또는 이전) 디스플레이로 옮겨 그 화면의 윈도우를 펼친다.
    private func switchDisplay(by delta: Int) {
        guard phase == .open else { return }
        let displays = SwitcherDisplay.all()
        guard displays.count > 1 else { return }
        let index = model.display.flatMap { current in displays.firstIndex { $0.id == current.id } } ?? 0
        let next = displays[((index + delta) % displays.count + displays.count) % displays.count]
        guard let screen = Self.screen(for: next), let panel else { return }

        applyGeometry(of: screen)
        panel.setFrame(screen.frame, display: false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.switchDisplay(to: next) }
        model.startLiveThumbnails(maxPixelSize: Self.thumbnailPixels)
    }

    /// 카드를 실제 윈도우 자리로 되돌리는 애니메이션 후 패널을 내린다.
    func close(activating window: WindowInfo? = nil) {
        guard phase == .open else { return }
        phase = .closing
        model.stopLiveThumbnails()
        if let window {
            model.selectedID = window.id
            model.raisedID = window.id
        }
        // 열린 뒤 데스크탑을 옮겨 왔다면, 그냥 닫아도 키 입력이 이전 데스크탑의 앱으로 돌아가
        // 화면이 되돌아가지 않도록 지금 데스크탑의 맨 앞 윈도우에 준다.
        let target = window ?? (spaceChangedWhileOpen ? model.frontVisibleWindow : nil)
        if let target {
            // 애니메이션이 끝날 때 실제 윈도우가 이미 맨 앞에 와 있도록 먼저 전환한다.
            DispatchQueue.global(qos: .userInteractive).async { WindowFocuser.focus(target) }
        }
        withAnimation(.easeInOut(duration: Self.collapseDuration)) { model.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDuration + 0.02) {
            self.panel?.orderOut(nil)
            self.model.endSearch()
            self.phase = .closed
            self.scheduleRefresh(captureThumbnails: true, delay: 0.4) // 전환 결과를 다음 번을 위해 찍어 둔다
        }
    }

    // MARK: 데스크탑 전환

    /// 선택기를 연(또는 마지막으로 따라간) 데스크탑
    private var openedSpace: UInt64 = 0
    /// 열려 있는 동안 데스크탑을 옮겼는지
    private var spaceChangedWhileOpen = false

    private static func activeSpace() -> UInt64 { CGSGetActiveSpace(CGSMainConnectionID()) }

    /// 열린 채로 데스크탑이 바뀌면(⌃⌘→, 트랙패드 스와이프) 닫지 않고 그 데스크탑의 윈도우로 다시 채운다.
    /// 패널은 모든 데스크탑에 함께 있으므로 그대로 따라오고, 키 입력만 되찾는다.
    /// 페이지는 macOS 데스크탑 전환처럼 통째로 옆으로 밀려 바뀐다 (패널이 화면을 덮고 있어 실제 전환은 가려진다).
    private func followSpaceChange() {
        guard phase == .open else { return }
        let previous = openedSpace
        let current = Self.activeSpace()
        guard current != previous else { return }
        openedSpace = current
        spaceChangedWhileOpen = true
        lastSpaceFollow = Date()
        panel?.makeKeyAndOrderFront(nil)

        // 오른쪽(순서가 뒤인) 데스크탑으로 가면 페이지가 왼쪽으로 밀린다.
        let order = SpaceMap.current().order
        let direction: CGFloat = (order[Int(current)] ?? 0) >= (order[Int(previous)] ?? 0) ? 1 : -1

        // 밀기는 바로 시작해야 하므로 지연 없는 목록으로 채우고, 정확한 목록은 뒤에서 바로잡는다.
        let quick = WindowCatalog.shared.quickList().map(WindowCatalog.applyPreferences)
        if let quick {
            model.slide(to: quick, direction: direction)
            model.startLiveThumbnails(maxPixelSize: Self.thumbnailPixels)
        }
        model.refreshWallpaper()

        DispatchQueue.global(qos: .userInteractive).async {
            let windows = WindowCatalog.applyPreferences(WindowCatalog.shared.refresh())
            Task { @MainActor in
                guard self.phase == .open, self.openedSpace == current else { return }
                if quick == nil {
                    self.model.slide(to: windows, direction: direction)
                } else {
                    self.model.update(windows)
                }
                self.model.startLiveThumbnails(maxPixelSize: Self.thumbnailPixels)
                self.panel?.makeKeyAndOrderFront(nil)
            }
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
    // 데스크탑 전환 중에는 macOS 가 새 데스크탑의 앱을 잠깐 앞으로 꺼내며 포커스를 가져가므로,
    // 데스크탑이 바뀌었거나 곧 바뀌는 경우엔 닫지 않고 키 입력을 되찾는다.
    func windowDidResignKey(_ notification: Notification) {
        guard phase == .open else { return }
        if Self.activeSpace() != openedSpace {
            panel?.makeKeyAndOrderFront(nil) // 전환 알림보다 먼저 왔다: 곧 followSpaceChange 가 채운다
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.phase == .open, self.panel?.isKeyWindow == false else { return }
            if Self.activeSpace() != self.openedSpace || self.spaceChangedRecently {
                self.panel?.makeKeyAndOrderFront(nil)
            } else {
                self.close()
            }
        }
    }

    /// 방금 데스크탑을 따라왔거나(0.6초) Unmouse 가 데스크탑 이동을 보냈다(1초):
    /// 그 직후의 포커스 이동은 전환 때문이다. 맨 끝 데스크탑에서 더 가려 하면 Dock 이 튕기며 포커스를 잠깐 가져간다.
    private var spaceChangedRecently: Bool {
        if let at = lastSpaceFollow, Date().timeIntervalSince(at) < 0.6 { return true }
        if let at = lastDesktopMove, Date().timeIntervalSince(at) < 1.0 { return true }
        return false
    }
    private var lastSpaceFollow: Date?
    private var lastDesktopMove: Date?

    /// 데스크탑 이동 단축키를 누르기 직전에 알린다. 열려 있으면 닫지 않고 새 데스크탑으로 따라간다.
    func noteDesktopMove() {
        guard phase == .open else { return }
        lastDesktopMove = Date()
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
            } else if code == kVK_ANSI_Grave {
                switchDisplay(by: flags == .shift ? -1 : 1)
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
        // 선택기는 기본으로 지금 데스크탑의 윈도우만 보여 준다. 다른 데스크탑은 설정에서 켠다.
        UserDefaults.standard.register(defaults: [includeMinimized: true, includeOtherSpaces: false, showMenuBarIcon: true])
    }
}

extension UserDefaults {
    /// KVO 로 지켜보기 위한 속성. 이름이 Preferences.showMenuBarIcon 키와 같아야 한다.
    @objc dynamic var showMenuBarIcon: Bool { bool(forKey: Preferences.showMenuBarIcon) }
}
