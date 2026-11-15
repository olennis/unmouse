import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

// 키보드 스크롤 모드: 지금 쓰는 윈도우에서 스크롤되는 영역을 찾아 그 위로 포인터를 옮기고,
// J/K 등의 키를 실제 스크롤 휠 입력으로 바꿔 보낸다. (스크롤은 포인터 아래 영역으로 전달되기 때문)

enum ScrollScanner {
    /// 맨 앞 윈도우에서 스크롤 가능한 영역들 (화면 전체 좌표). 넓은 것부터.
    static func areas(app: NSRunningApplication) -> (areas: [CGRect], windowFrame: CGRect?) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        let window: AXUIElement? = appElement.attribute(kAXFocusedWindowAttribute) ?? appElement.attribute(kAXMainWindowAttribute)
        guard let window, let windowFrame = HintScanner.read(window)?.frame else { return ([], nil) }

        var found: [CGRect] = []
        let deadline = DispatchTime.now() + .milliseconds(250)
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast() {
            visited += 1
            if visited > 1500 || DispatchTime.now() > deadline { break }
            guard let info = HintScanner.read(element) else { continue }
            if info.role == "AXScrollArea" || info.role == "AXWebArea", let frame = info.frame {
                let visible = frame.intersection(windowFrame)
                if !visible.isNull, visible.width >= 120, visible.height >= 80 {
                    // 거의 같은 자리의 중첩 영역(스크롤 영역 안의 웹 영역 등)은 하나로 친다.
                    let duplicate = found.contains { abs($0.midX - visible.midX) < 40 && abs($0.midY - visible.midY) < 40 }
                    if !duplicate { found.append(visible) }
                }
            }
            // 스크롤 영역은 윈도우 구조의 얕은 곳에 있다. 내용(웹 페이지 등) 깊숙이는 들어가지 않는다.
            if depth < 12, info.role != "AXWebArea", info.role != "AXTable", info.role != "AXOutline" {
                for child in info.children.reversed() { stack.append((child, depth + 1)) }
            }
        }
        found.sort { $0.width * $0.height > $1.width * $1.height }
        return (found.isEmpty ? [windowFrame] : found, windowFrame)
    }
}

@MainActor
final class ScrollModel: ObservableObject {
    /// 패널 좌표계의 스크롤 영역들
    @Published var areas: [CGRect] = []
    @Published var index = 0
}

@MainActor
final class ScrollController: NSObject, NSWindowDelegate {
    let model = ScrollModel()
    var onNeedPermission: (() -> Void)?

    private enum Phase { case closed, scanning, open }
    private var phase = Phase.closed
    private var panel: SwitcherPanel?

    /// 화면 전체 좌표(CoreGraphics)의 스크롤 영역들. model.areas 와 같은 순서.
    private var areas: [CGRect] = []
    private var target: CGPoint { areas.indices.contains(model.index) ? CGPoint(x: areas[model.index].midX, y: areas[model.index].midY) : .zero }

    // 누르고 있는 방향 키 → 누르기 시작한 시각
    private var held: [Int: Date] = [:]
    /// 반 페이지·맨 위/아래처럼 한 번에 이동할 남은 거리 (px, +는 아래/오른쪽)
    private var pending = CGPoint.zero
    private var pendingSpeed: CGFloat = 4000
    private var remainder = CGPoint.zero
    private var timer: Timer?
    private var lastTick = Date()
    private var lastG: Date?

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
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        phase = .scanning
        DispatchQueue.global(qos: .userInteractive).async {
            let result = ScrollScanner.areas(app: app)
            Task { @MainActor in self.present(result.areas, windowFrame: result.windowFrame) }
        }
    }

    private func present(_ found: [CGRect], windowFrame: CGRect?) {
        guard phase == .scanning else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func cgFrame(_ screen: NSScreen) -> CGRect {
            CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        }
        let center = windowFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        guard !found.isEmpty,
              let screen = NSScreen.screens.first(where: { s in center.map { cgFrame(s).contains($0) } ?? false })
                ?? NSScreen.main ?? NSScreen.screens.first else {
            phase = .closed
            return
        }
        let screenFrame = cgFrame(screen)
        areas = found
        model.areas = found.map { $0.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
        model.index = 0

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        phase = .open
        movePointer()

        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        timer?.invalidate()
        timer = nil
        held = [:]
        pending = .zero
        panel?.orderOut(nil)
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true // 스크롤 입력이 패널을 지나 아래 윈도우로 가야 한다
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.keyDown(event) ?? false }
        panel.keyUpHandler = { [weak self] event in self?.held[Int(event.keyCode)] = nil }
        panel.contentView = NSHostingView(rootView: ScrollOverlay(model: model))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// 스크롤 입력은 포인터 아래의 영역이 받으므로 포인터를 영역 가운데로 옮긴다.
    private func movePointer() {
        CGWarpMouseCursorPosition(target)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    // MARK: 키 처리

    private static let directions: [Int: CGPoint] = [
        kVK_ANSI_J: CGPoint(x: 0, y: 1), kVK_DownArrow: CGPoint(x: 0, y: 1),
        kVK_ANSI_K: CGPoint(x: 0, y: -1), kVK_UpArrow: CGPoint(x: 0, y: -1),
        kVK_ANSI_L: CGPoint(x: 1, y: 0), kVK_RightArrow: CGPoint(x: 1, y: 0),
        kVK_ANSI_H: CGPoint(x: -1, y: 0), kVK_LeftArrow: CGPoint(x: -1, y: 0),
    ]

    private func keyDown(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        let shift = event.modifierFlags.contains(.shift)
        let pageHeight = areas.indices.contains(model.index) ? areas[model.index].height : 600

        if Self.directions[code] != nil {
            if held[code] == nil { held[code] = Date() }
            return true
        }
        guard !event.isARepeat || code == kVK_ANSI_D || code == kVK_ANSI_U || code == kVK_Space else { return true }

        switch code {
        case kVK_Escape:
            close()
        case kVK_Tab:
            guard areas.count > 1 else { break }
            model.index = (model.index + (shift ? areas.count - 1 : 1)) % areas.count
            pending = .zero
            movePointer()
        case kVK_ANSI_D:
            jump(by: pageHeight / 2)
        case kVK_ANSI_U:
            jump(by: -pageHeight / 2)
        case kVK_Space:
            jump(by: (shift ? -1 : 1) * pageHeight * 0.9)
        case kVK_ANSI_G:
            if shift {
                jump(by: 3_000_000, speed: 600_000) // 맨 아래
            } else if let last = lastG, Date().timeIntervalSince(last) < 0.5 {
                lastG = nil
                jump(by: -3_000_000, speed: 600_000) // gg: 맨 위
            } else {
                lastG = Date()
            }
        default:
            break
        }
        return true // 스크롤 모드에서는 모든 키를 여기서 소비한다
    }

    private func jump(by distance: CGFloat, speed: CGFloat? = nil) {
        pending.y = distance
        pendingSpeed = speed ?? max(abs(distance) / 0.16, 2500) // 약 0.16초에 걸쳐 부드럽게
    }

    // MARK: 스크롤 보내기

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.05)
        lastTick = now
        var delta = CGPoint.zero

        // 누르고 있는 키: 처음엔 천천히, 누르고 있을수록 빠르게
        for (code, since) in held {
            guard let direction = Self.directions[code] else { continue }
            let ramp = min(now.timeIntervalSince(since) / 0.7, 1)
            let speed = 500 + 1700 * ramp
            delta.x += direction.x * speed * dt
            delta.y += direction.y * speed * dt
        }
        if pending.y != 0 {
            let step = min(abs(pending.y), pendingSpeed * dt) * (pending.y > 0 ? 1 : -1)
            pending.y -= step
            delta.y += step
        }

        remainder.x += delta.x
        remainder.y += delta.y
        let dx = remainder.x.rounded(.towardZero)
        let dy = remainder.y.rounded(.towardZero)
        guard dx != 0 || dy != 0 else { return }
        remainder.x -= dx
        remainder.y -= dy

        // 휠 값은 +가 위/왼쪽으로 스크롤
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        event.location = target
        event.flags = [] // ⇧ 를 누른 채여도 가로 스크롤로 바뀌지 않게
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - 화면

struct ScrollOverlay: View {
    @ObservedObject var model: ScrollModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if model.areas.indices.contains(model.index) {
                let frame = model.areas[model.index]
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .animation(.snappy(duration: 0.2), value: model.index)
            }
            VStack {
                Spacer()
                HStack(spacing: 16) {
                    legend(["J", "K"], L10n.text("Scroll"))
                    legend(["D", "U"], L10n.text("Half page"))
                    legend(["G", "G"], L10n.text("Top"))
                    legend(["⇧", "G"], L10n.text("Bottom"))
                    if model.areas.count > 1 { legend(["⇥"], L10n.text("Switch area")) }
                    legend(["esc"], L10n.text("Exit"))
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
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(key) }
            Text(text).foregroundStyle(.secondary).padding(.leading, 2)
        }
    }
}
