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
        if pendingSpace != nil { finishDesktopMove() } // 전환 도중에 닫았다
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

    /// 열린 채로 데스크탑이 바뀌면(⌃⌘→, 트랙패드 스와이프) 닫지 않고 그 데스크탑의 윈도우로 채운다.
    ///
    /// 단축키로 옮긴 경우엔 새 데스크탑의 선택기가 이미 전환 애니메이션과 함께 들어와 있다.
    /// 원래 선택기를 같은 내용으로 바꿔 그 자리에 다시 놓고, 두 번째 선택기는 내린다 (눈에 보이는 변화 없음).
    /// 트랙패드 스와이프는 미리 알 수 없어, 도착한 뒤 새 데스크탑 윈도우로 서서히 바꾼다.
    private func followSpaceChange() {
        guard phase == .open else { return }
        let previous = openedSpace
        let current = Self.activeSpace()
        guard current != previous else { return }
        openedSpace = current
        spaceChangedWhileOpen = true
        lastSpaceFollow = Date()

        if pendingSpace == Int(current) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.load(pendingWindows, frontmostPID: nil, displays: model.displays, display: model.display)
            }
            // 바뀐 내용이 한 번 그려진 다음 바꿔치기한다.
            DispatchQueue.main.async { self.finishDesktopMove() }
        } else {
            if pendingSpace != nil { finishDesktopMove() } // 다른 데스크탑에 도착: 준비해 둔 것은 버린다
            panel?.makeKeyAndOrderFront(nil)
            if let quick = WindowCatalog.shared.quickList().map(WindowCatalog.applyPreferences) {
                model.slide(to: quick, direction: 1, fade: true)
            }
        }
        model.startLiveThumbnails(maxPixelSize: Self.thumbnailPixels)
        model.refreshWallpaper()

        // 정확한 목록으로 바로잡는다 (구성이 같으면 아무것도 바뀌지 않는다).
        DispatchQueue.global(qos: .userInteractive).async {
            let windows = WindowCatalog.applyPreferences(WindowCatalog.shared.refresh())
            Task { @MainActor in
                guard self.phase == .open, self.openedSpace == current else { return }
                self.model.update(windows)
                self.model.startLiveThumbnails(maxPixelSize: Self.thumbnailPixels)
            }
        }
    }

    private func activate(_ window: WindowInfo) {
        close(activating: window)
    }

    private func makePanel() -> SwitcherPanel {
        makePanel(model: model, interactive: true)
    }

    /// interactive: false 는 데스크탑 전환 동안만 보이는 두 번째 선택기 (입력을 받지 않는다).
    private func makePanel(model: SwitcherModel, interactive: Bool) -> SwitcherPanel {
        let panel = SwitcherPanel(contentRect: .zero,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        // Dock·메뉴 막대 바로 아래: Mission Control 처럼 둘은 그대로 보이고 일반 윈도우만 덮는다.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        panel.collectionBehavior = Self.joinAllSpaces
        guard interactive else {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = true
            panel.contentView = NSHostingView(rootView: SwitcherView(model: model))
            return panel
        }
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
        // 전환 애니메이션 중: 선택기는 떠나는 데스크탑에 묶여 있으니 앞으로 꺼내면 안 된다 (되돌아간다).
        if pendingSpace != nil { return }
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

    // MARK: 데스크탑 전환 애니메이션에 태우기

    /// 단축키로 옮겨 가는 중인 데스크탑과 그곳에서 보일 윈도우
    private var pendingSpace: Int?
    private var pendingWindows: [WindowInfo] = []
    /// 옮겨 갈 데스크탑에 미리 올려 두는 두 번째 선택기 (그 데스크탑의 윈도우로 채워져 있다)
    private var arrivalPanel: SwitcherPanel?
    private let arrivalModel = SwitcherModel()

    private static let joinAllSpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    private static let ownSpaceOnly: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]

    /// 데스크탑 이동 단축키를 누른 순간, 실제 전환 전에 준비한다.
    ///
    /// 선택기를 흉내 낸 애니메이션으로 밀면 macOS 의 전환과 어긋난다. 대신 macOS 의 진짜 전환에 태운다:
    /// 지금 선택기는 지금 데스크탑에만 남기고, 옮겨 갈 데스크탑에는 그곳 윈도우로 채운 선택기를 미리 올려 둔다.
    /// 그러면 데스크탑이 밀릴 때 두 선택기가 각자 자기 데스크탑과 함께 밀린다 (끝에서 튕기는 것까지 macOS 그대로).
    func beginDesktopMove(_ direction: DesktopSwitcher.Direction) {
        guard phase == .open, pendingSpace == nil, let panel else { return }
        lastDesktopMove = Date()
        let cid = CGSMainConnectionID()
        let from = Int(Self.activeSpace())
        guard let target = SpaceMap.current().neighbor(of: from, by: direction == .right ? 1 : -1),
              let predicted = WindowCatalog.shared.windows(onSpace: target).map(WindowCatalog.applyPreferences)
        else { return } // 맨 끝 데스크탑(macOS 가 튕긴다) 또는 목록 캐시 없음(도착한 뒤 채운다)

        // 옮겨 갈 데스크탑의 선택기: 지금 선택기와 같은 화면·같은 모습으로 꾸려 그 데스크탑에 올린다.
        let arrival = arrivalPanel ?? makePanel(model: arrivalModel, interactive: false)
        arrivalPanel = arrival
        arrivalModel.safeInsets = model.safeInsets
        arrivalModel.contentRect = model.contentRect
        arrivalModel.pageWidth = model.pageWidth
        arrivalModel.screenOrigin = model.screenOrigin
        arrivalModel.thumbnails = model.thumbnails
        arrivalModel.wallpaper = model.wallpaper
        arrivalModel.expanded = true
        arrivalModel.load(predicted, frontmostPID: nil, displays: model.displays, display: model.display)
        arrival.collectionBehavior = Self.ownSpaceOnly
        arrival.setFrame(panel.frame, display: false)
        // 지금 선택기 바로 뒤에 놓아(화면을 덮고 있어 보이지 않는다) 완전히 그려 둔 다음 옮긴다.
        // 투명하게 띄워 옮기면 그 데스크탑이 보일 때까지 다시 그려지지 않아 전환 중에 비어 보인다.
        arrival.alphaValue = 1
        arrival.order(.below, relativeTo: panel.windowNumber)
        arrival.contentView?.layoutSubtreeIfNeeded()
        arrival.display()

        // 지금 선택기는 지금 데스크탑에만 남겨, 데스크탑과 함께 밀려 나가게 한다.
        panel.collectionBehavior = Self.ownSpaceOnly
        SLSMoveWindowsToManagedSpace(cid, [panel.windowNumber] as CFArray, UInt64(from))
        pendingSpace = target
        pendingWindows = predicted

        // SwiftUI 가 새 내용을 다 그린 다음 프레임에 옮긴다 (실제 전환은 키를 뗀 뒤라 충분히 앞선다).
        DispatchQueue.main.async {
            guard self.pendingSpace == target else { return }
            arrival.display()
            SLSMoveWindowsToManagedSpace(cid, [arrival.windowNumber] as CFArray, UInt64(target))
            let landed = SpaceMap.spaces(of: CGWindowID(arrival.windowNumber))
            // 문제 진단용: `defaults read app.unmouse.Unmouse lastDesktopMove`
            UserDefaults.standard.set("from=\(from) target=\(target) arrivalSpaces=\(landed)", forKey: "lastDesktopMove")
            if landed != [target] { self.finishDesktopMove() } // 이 macOS 에서 옮길 수 없다: 도착한 뒤 채운다
        }

        // 전환이 일어나지 않으면(다른 앱이 단축키를 가로채는 등) 원래대로 되돌린다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard self.pendingSpace == target, Int(Self.activeSpace()) != target else { return }
            self.finishDesktopMove()
        }
    }

    /// 두 번째 선택기를 내리고 원래 선택기를 다시 모든 데스크탑에 둔다.
    private func finishDesktopMove() {
        pendingSpace = nil
        pendingWindows = []
        panel?.collectionBehavior = Self.joinAllSpaces
        if phase == .open { panel?.makeKeyAndOrderFront(nil) }
        arrivalPanel?.orderOut(nil)
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
