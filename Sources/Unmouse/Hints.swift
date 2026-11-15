import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

// 클릭 힌트: 지금 쓰는 윈도우에서 클릭할 수 있는 요소마다 글자를 붙이고,
// 그 글자를 입력하면 해당 위치를 클릭한다 (브라우저의 Vimium `f` 와 같은 방식을 모든 앱에서).

struct HintTarget: Identifiable {
    let id: Int
    /// 패널 좌표계(왼쪽 위 원점)에서의 요소 영역
    let frame: CGRect
    /// 화면 전체 좌표(CoreGraphics)에서 클릭할 지점
    let clickPoint: CGPoint
    var label: String = ""
}

// MARK: - 요소 탐색

enum HintScanner {
    /// 그 자체가 클릭 대상인 역할
    private static let clickable: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXComboBox", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXColorWell",
        "AXMenuItem", "AXMenuBarItem", "AXRow", "AXDockItem", "AXSwitch", "AXToggle", "AXTab", "AXSegment",
    ]
    /// 누르기 동작(AXPress)이 있을 때만 클릭 대상으로 치는 역할
    private static let clickableIfPressable: Set<String> = ["AXImage", "AXCell"]
    /// 안쪽을 더 볼 필요가 없는 역할
    private static let leaves: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXComboBox", "AXSlider", "AXStaticText", "AXImage", "AXMenuItem", "AXMenuBarItem",
        "AXDisclosureTriangle", "AXColorWell", "AXIncrementor",
    ]
    private static let ignored: Set<String> = ["AXScrollBar", "AXValueIndicator", "AXGrowArea", "AXMenuBar", "AXSplitter"]
    /// 웹 페이지 내용을 손쉬운 사용에 내놓으려면 따로 켜 줘야 하는 Chromium 계열 브라우저
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.naver.Whale", "org.chromium.Chromium",
    ]

    private static let attributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray

    struct Result {
        var frames: [CGRect] = []        // 화면 전체 좌표(CoreGraphics)
        var windowFrame: CGRect?
    }

    static func scan(app: NSRunningApplication) -> Result {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.4)
        // Electron 앱과 Chromium 브라우저는 요청이 있어야 화면 내용을 손쉬운 사용에 공개한다.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundleID = app.bundleIdentifier, chromiumBrowsers.contains(bundleID) {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }

        var result = Result()
        var seen = Set<[Int]>()
        func add(_ frame: CGRect) {
            let key = [Int(frame.minX / 3), Int(frame.minY / 3), Int(frame.width / 3), Int(frame.height / 3)]
            if seen.insert(key).inserted { result.frames.append(frame) }
        }

        // 메뉴 막대
        if let menuBar: AXUIElement = appElement.attribute(kAXMenuBarAttribute),
           let items: [AXUIElement] = menuBar.attribute(kAXChildrenAttribute) {
            for item in items {
                if let frame = read(item)?.frame, frame.width > 4 { add(frame) }
            }
        }

        let window: AXUIElement? = appElement.attribute(kAXFocusedWindowAttribute) ?? appElement.attribute(kAXMainWindowAttribute)
        guard let window, let windowFrame = read(window)?.frame else { return result }
        result.windowFrame = windowFrame

        let deadline = DispatchTime.now() + .milliseconds(700)
        var stack: [(element: AXUIElement, clip: CGRect, depth: Int)] = [(window, windowFrame, 0)]
        var visited = 0
        while let (element, clip, depth) = stack.popLast() {
            visited += 1
            if visited > 8000 || result.frames.count >= 700 || DispatchTime.now() > deadline { break }
            guard let info = read(element) else { continue }
            if ignored.contains(info.role) { continue }

            var childClip = clip
            if let frame = info.frame {
                let visible = frame.intersection(clip)
                // 스크롤되어 가려졌거나 윈도우 밖에 있는 부분은 건너뛴다.
                if visible.isNull || visible.width < 4 || visible.height < 4 {
                    if frame.width > 0, frame.height > 0 { continue }
                } else {
                    var isTarget = clickable.contains(info.role)
                    if !isTarget, clickableIfPressable.contains(info.role) {
                        var names: CFArray?
                        AXUIElementCopyActionNames(element, &names)
                        isTarget = (names as? [String])?.contains(kAXPressAction) ?? false
                    }
                    if isTarget, depth > 0 { add(visible) }
                    if info.role == "AXScrollArea" || info.role == "AXWebArea" { childClip = visible }
                }
            }

            if leaves.contains(info.role) || depth > 60 { continue }
            var children = info.children
            if info.role == "AXOutline" || info.role == "AXTable" {
                // 표·목록은 화면에 보이는 줄만 (수천 줄짜리 목록 대비)
                children = element.attribute("AXVisibleRows") ?? children
            }
            // 스택이라 뒤집어 넣어야 화면 순서(위→아래)대로 훑는다.
            for child in children.reversed() { stack.append((child, childClip, depth + 1)) }
        }
        return result
    }

    struct Info {
        let role: String
        let frame: CGRect?
        let children: [AXUIElement]
    }

    /// 역할·위치·크기·자식을 한 번의 호출로 읽는다 (앱과의 왕복 횟수를 줄이기 위함).
    static func read(_ element: AXUIElement) -> Info? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
              let list = values as? [AnyObject], list.count == 4 else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        var frame: CGRect?
        if CFGetTypeID(list[1]) == AXValueGetTypeID(), CFGetTypeID(list[2]) == AXValueGetTypeID(),
           AXValueGetValue(list[1] as! AXValue, .cgPoint, &point), AXValueGetValue(list[2] as! AXValue, .cgSize, &size) {
            frame = CGRect(origin: point, size: size)
        }
        let children = CFGetTypeID(list[3]) == CFArrayGetTypeID() ? (list[3] as? [AXUIElement] ?? []) : []
        return Info(role: list[0] as? String ?? "", frame: frame, children: children)
    }

    /// 힌트 글자: 요소 수에 맞춰 모두 같은 길이로 (26개 이하면 한 글자, 676개 이하면 두 글자…)
    static func labels(count: Int) -> [String] {
        let alphabet = HintKey.all.prefix(26).map(\.label)
        var length = 1
        var capacity = alphabet.count
        while capacity < count {
            length += 1
            capacity *= alphabet.count
        }
        return (0..<count).map { index in
            var n = index
            var chars: [String] = []
            for _ in 0..<length {
                chars.append(alphabet[n % alphabet.count])
                n /= alphabet.count
            }
            return chars.reversed().joined()
        }
    }
}

// MARK: - 상태

@MainActor
final class HintModel: ObservableObject {
    @Published var targets: [HintTarget] = []
    @Published var typed = ""
    @Published var message: String?

    var matching: [HintTarget] { targets.filter { $0.label.hasPrefix(typed) } }
}

// MARK: - 컨트롤러

@MainActor
final class HintController: NSObject, NSWindowDelegate {
    let model = HintModel()
    var onNeedPermission: (() -> Void)?

    private enum Phase { case closed, scanning, open }
    private var phase = Phase.closed
    private var panel: SwitcherPanel?

    func toggle() {
        switch phase {
        case .open: close()
        case .scanning: break
        case .closed: show()
        }
    }

    private func show() {
        guard AXIsProcessTrusted() else {
            onNeedPermission?()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return }
        phase = .scanning
        DispatchQueue.global(qos: .userInteractive).async {
            let result = HintScanner.scan(app: app)
            Task { @MainActor in self.present(result) }
        }
    }

    private func present(_ result: HintScanner.Result) {
        guard phase == .scanning else { return }
        // 윈도우가 놓인 화면 위에 띄운다.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func cgFrame(_ screen: NSScreen) -> CGRect {
            CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        }
        let center = result.windowFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        guard let screen = NSScreen.screens.first(where: { s in center.map { cgFrame(s).contains($0) } ?? false })
                ?? NSScreen.main ?? NSScreen.screens.first else {
            phase = .closed
            return
        }
        let screenFrame = cgFrame(screen)

        let frames = result.frames
            .filter { screenFrame.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        let labels = HintScanner.labels(count: frames.count)
        model.targets = zip(frames, labels).enumerated().map { index, pair in
            HintTarget(id: index,
                       frame: pair.0.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY),
                       clickPoint: CGPoint(x: pair.0.midX, y: pair.0.midY),
                       label: pair.1)
        }
        model.typed = ""
        model.message = frames.isEmpty ? L10n.text("No clickable elements found") : nil

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        phase = .open

        if frames.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.model.message != nil { self?.close() }
            }
        }
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        panel?.orderOut(nil)
        model.targets = []
        model.message = nil
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.level = .popUpMenu // 메뉴 막대 항목 위에도 글자가 보이도록
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.contentView = NSHostingView(rootView: HintOverlay(model: model))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: 키 처리

    private func handleKey(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        if code == kVK_Escape {
            close()
            return true
        }
        if code == kVK_Delete {
            if !model.typed.isEmpty { model.typed.removeLast() }
            return true
        }
        guard let letter = HintKey.all.prefix(26).first(where: { $0.keyCode == event.keyCode })?.label else { return true }
        let next = model.typed + letter
        let candidates = model.targets.filter { $0.label.hasPrefix(next) }
        guard !candidates.isEmpty else { return true } // 없는 글자는 무시
        model.typed = next
        if let target = candidates.first, candidates.count == 1, target.label == next {
            let flags = event.modifierFlags
            close()
            Clicker.click(at: target.clickPoint,
                          rightButton: flags.contains(.shift),
                          command: flags.contains(.command))
        }
        return true
    }
}

// MARK: - 클릭 실행

enum Clicker {
    /// 포인터를 옮기고 실제 마우스 클릭 이벤트를 보낸다. 어떤 앱·어떤 요소에서도 같은 방식으로 동작한다.
    static func click(at point: CGPoint, rightButton: Bool, command: Bool) {
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05) { // 힌트 패널이 내려간 뒤에
            let source = CGEventSource(stateID: .hidSystemState)
            let button: CGMouseButton = rightButton ? .right : .left
            let flags: CGEventFlags = command && !rightButton ? .maskCommand : []
            func post(_ type: CGEventType) {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                          mouseCursorPosition: point, mouseButton: button) else { return }
                event.flags = flags
                if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
                event.post(tap: .cghidEventTap)
            }
            post(.mouseMoved)
            usleep(30_000)
            post(rightButton ? .rightMouseDown : .leftMouseDown)
            usleep(30_000)
            post(rightButton ? .rightMouseUp : .leftMouseUp)
        }
    }
}

// MARK: - 화면

struct HintOverlay: View {
    @ObservedObject var model: HintModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.targets) { target in
                if target.label.hasPrefix(model.typed) {
                    HintBadge(label: target.label, typedCount: model.typed.count)
                        .position(x: target.frame.minX + min(target.frame.width / 2, 18),
                                  y: target.frame.midY)
                }
            }
            VStack {
                Spacer()
                Group {
                    if let message = model.message {
                        Label(message, systemImage: "cursorarrow.slash")
                    } else {
                        HStack(spacing: 16) {
                            legend(["A", "–", "Z"], L10n.text("Click"))
                            legend(["⇧"], L10n.text("Right-click"))
                            legend(["⌘"], L10n.text("⌘-click"))
                            legend(["⌫"], L10n.text("Delete"))
                            legend(["esc"], L10n.text("Cancel"))
                        }
                    }
                }
                .font(.callout)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 110)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private func legend(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                if key == "–" { Text(key).foregroundStyle(.secondary) } else { KeyCap(key) }
            }
            Text(text).foregroundStyle(.secondary).padding(.leading, 2)
        }
    }
}

struct HintBadge: View {
    let label: String
    let typedCount: Int

    var body: some View {
        HStack(spacing: 0) {
            Text(label.prefix(typedCount)).foregroundStyle(.white.opacity(0.4))
            Text(label.dropFirst(typedCount)).foregroundStyle(.white)
        }
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .padding(.horizontal, 5)
        .frame(minWidth: 20, minHeight: 19)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .fixedSize()
    }
}
