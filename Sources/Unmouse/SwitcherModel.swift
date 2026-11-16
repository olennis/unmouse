import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

/// 윈도우마다 붙는 한 글자 단축키. 입력 소스(한글/영문)와 무관하도록 키 코드로 비교한다.
struct HintKey {
    let keyCode: UInt16
    let label: String

    /// 홈 로우 → 윗줄 → 아랫줄 → 숫자 순
    static let all: [HintKey] = [
        (kVK_ANSI_A, "A"), (kVK_ANSI_S, "S"), (kVK_ANSI_D, "D"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"),
        (kVK_ANSI_H, "H"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
        (kVK_ANSI_Q, "Q"), (kVK_ANSI_W, "W"), (kVK_ANSI_E, "E"), (kVK_ANSI_R, "R"), (kVK_ANSI_T, "T"),
        (kVK_ANSI_Y, "Y"), (kVK_ANSI_U, "U"), (kVK_ANSI_I, "I"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
        (kVK_ANSI_Z, "Z"), (kVK_ANSI_X, "X"), (kVK_ANSI_C, "C"), (kVK_ANSI_V, "V"), (kVK_ANSI_B, "B"),
        (kVK_ANSI_N, "N"), (kVK_ANSI_M, "M"),
        (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"),
        (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"), (kVK_ANSI_0, "0"),
    ].map { HintKey(keyCode: UInt16($0.0), label: $0.1) }
}

/// 연결된 디스플레이 하나. 선택기는 한 번에 한 디스플레이의 윈도우만 펼친다.
struct SwitcherDisplay: Equatable {
    let id: CGDirectDisplayID
    let name: String
    /// CoreGraphics 좌표(주 화면 왼쪽 위 원점)의 화면 영역
    let frame: CGRect
    let scale: CGFloat

    /// 왼쪽 → 오른쪽(같으면 위 → 아래) 순서. 디스플레이 전환 키가 이 순서로 돈다.
    @MainActor
    static func all() -> [SwitcherDisplay] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { screen -> SwitcherDisplay? in
            guard let id = screen.displayID else { return nil }
            let frame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                               width: screen.frame.width, height: screen.frame.height)
            return SwitcherDisplay(id: id, name: screen.localizedName, frame: frame, scale: screen.backingScaleFactor)
        }
        .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }

    /// 윈도우가 속한 디스플레이: 가장 많이 겹치는 화면, 어디와도 겹치지 않으면 가장 가까운 화면.
    /// 다른 데스크탑·최소화된 윈도우도 마지막 위치를 그대로 갖고 있어서 같은 방식으로 판별된다.
    static func owner(of frame: CGRect, among displays: [SwitcherDisplay]) -> SwitcherDisplay? {
        func overlap(_ d: SwitcherDisplay) -> CGFloat {
            let r = d.frame.intersection(frame)
            return r.isNull ? 0 : r.width * r.height
        }
        if let best = displays.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
        func distance(_ d: SwitcherDisplay) -> CGFloat {
            hypot(d.frame.midX - frame.midX, d.frame.midY - frame.midY)
        }
        return displays.min { distance($0) < distance($1) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Mission Control 식 배치: 윈도우의 실제 크기 비율과 화면에서의 상대 위치(위/아래, 왼쪽/오른쪽)를 유지하면서
/// 서로 겹치지 않게 줄 단위로 펼친다.
struct MissionLayout {
    static let labelBlock: CGFloat = 42   // 카드 아래 이름표 영역
    static let hGap: CGFloat = 36
    static let vGap: CGFloat = 18
    static let maxScale: CGFloat = 0.72

    var frames: [CGWindowID: CGRect] = [:]
    var rows: [[CGWindowID]] = []
    var order: [CGWindowID] { rows.flatMap { $0 } }

    static func compute(_ windows: [WindowInfo], in rect: CGRect) -> MissionLayout {
        guard !windows.isEmpty, rect.width > 0, rect.height > 0 else { return MissionLayout() }

        // 아주 작은 윈도우는 알아볼 수 있을 만큼만 키운다.
        let tallest = windows.map(\.frame.height).max() ?? 1
        var sizes: [CGWindowID: CGSize] = [:]
        for w in windows {
            let factor = min(max(tallest * 0.45 / max(w.frame.height, 1), 1), 2.5)
            sizes[w.id] = CGSize(width: max(w.frame.width, 1) * factor, height: max(w.frame.height, 1) * factor)
        }

        // 보이는 윈도우는 화면 위치 순, 나머지(다른 데스크탑·최소화)는 그 뒤에.
        func key(_ w: WindowInfo, _ position: CGFloat) -> (Int, Int, Int) {
            w.location == .visible ? (0, Int(position / 60), w.rank) : (1, 0, w.rank)
        }
        let byY = windows.sorted { key($0, $0.frame.midY) < key($1, $1.frame.midY) }
        let totalWidth = byY.reduce(0) { $0 + sizes[$1.id]!.width }

        var best: (scale: CGFloat, rows: [[WindowInfo]])?
        for rowCount in 1...windows.count {
            var rows: [[WindowInfo]] = []
            var current: [WindowInfo] = []
            var used: CGFloat = 0
            for (i, w) in byY.enumerated() {
                let width = sizes[w.id]!.width
                let rowsAfterCurrent = rowCount - rows.count - 1
                let overTarget = used + width / 2 > totalWidth / CGFloat(rowCount) * CGFloat(rows.count + 1)
                if !current.isEmpty, rowsAfterCurrent > 0, overTarget || byY.count - i <= rowsAfterCurrent {
                    rows.append(current)
                    current = []
                }
                current.append(w)
                used += width
            }
            rows.append(current)

            var scale = maxScale
            var heights: CGFloat = 0
            for row in rows {
                let width = row.reduce(0) { $0 + sizes[$1.id]!.width }
                scale = min(scale, (rect.width - hGap * CGFloat(row.count - 1)) / width)
                heights += row.map { sizes[$0.id]!.height }.max() ?? 0
            }
            let n = CGFloat(rows.count)
            scale = min(scale, (rect.height - labelBlock * n - vGap * (n - 1)) / heights)
            if scale > (best?.scale ?? 0) + 0.0001 { best = (scale, rows) }
        }
        guard let best, best.scale > 0 else { return MissionLayout() }

        var layout = MissionLayout()
        let scale = best.scale
        let rowHeights = best.rows.map { row in (row.map { sizes[$0.id]!.height }.max() ?? 0) * scale }
        let n = CGFloat(best.rows.count)
        var y = rect.midY - (rowHeights.reduce(0, +) + labelBlock * n + vGap * (n - 1)) / 2
        for (row, rowHeight) in zip(best.rows, rowHeights) {
            let sorted = row.sorted { key($0, $0.frame.midX) < key($1, $1.frame.midX) }
            let rowWidth = sorted.reduce(0) { $0 + sizes[$1.id]!.width * scale } + hGap * CGFloat(sorted.count - 1)
            var x = rect.midX - rowWidth / 2
            for w in sorted {
                let size = sizes[w.id]!
                let frame = CGRect(x: x, y: y + (rowHeight - size.height * scale) / 2,
                                   width: size.width * scale, height: size.height * scale)
                layout.frames[w.id] = frame.integral
                x += frame.width + hGap
            }
            layout.rows.append(sorted.map(\.id))
            y += rowHeight + labelBlock + vGap
        }
        return layout
    }
}

@MainActor
final class SwitcherModel: ObservableObject {
    /// 검색으로 걸러지고 배치 순서(왼쪽 위 → 오른쪽 아래)로 정렬된 윈도우
    @Published private(set) var items: [WindowInfo] = []
    @Published private(set) var layout = MissionLayout()
    @Published var query = "" { didSet { if query != oldValue { relayout() } } }
    @Published var isSearching = false
    @Published var selectedID: CGWindowID?
    @Published var thumbnails: [CGWindowID: CGImage] = [:]
    @Published var accessibilityGranted = true
    @Published var screenCaptureGranted = true
    /// false: 카드가 실제 윈도우 자리에 겹쳐 있음 / true: Mission Control 배치로 펼쳐짐
    @Published var expanded = false
    /// 지금 화면의 바탕화면 그림 (Mission Control 식 배경). 화면 녹화 권한이 없으면 nil.
    @Published var wallpaper: CGImage?
    /// 닫히는 동안 맨 위에 그릴 카드 (선택해서 이동하는 윈도우)
    @Published var raisedID: CGWindowID?

    /// 패널 좌표계(왼쪽 위 원점)에서 카드를 펼칠 영역
    var contentRect = CGRect.zero
    /// 메뉴 막대·Dock 이 차지하는 가장자리
    @Published var safeInsets = EdgeInsets()
    /// 패널이 덮는 화면의 CoreGraphics 좌표 원점
    var screenOrigin = CGPoint.zero

    /// 연결된 디스플레이 (전환 순서대로)
    @Published private(set) var displays: [SwitcherDisplay] = []
    /// 지금 펼치고 있는 디스플레이. nil 이면 디스플레이로 거르지 않는다 (데모 등).
    @Published private(set) var display: SwitcherDisplay?

    /// 모든 디스플레이의 윈도우
    private var allWindows: [WindowInfo] = []
    /// 그중 지금 디스플레이에 있는 윈도우
    private var windows: [WindowInfo] = []
    private(set) var hints: [CGWindowID: String] = [:]
    private var hintTargets: [UInt16: CGWindowID] = [:]
    /// 디스플레이마다 찍어 둔 바탕화면
    private var wallpapers: [CGDirectDisplayID: CGImage] = [:]

    var selected: WindowInfo? { items.first { $0.id == selectedID } }

    func load(_ newWindows: [WindowInfo], frontmostPID: pid_t?,
              displays: [SwitcherDisplay] = [], display: SwitcherDisplay? = nil) {
        self.displays = displays
        self.display = display
        allWindows = newWindows
        windows = filterToDisplay(newWindows)
        if let display, let image = wallpapers[display.id] { wallpaper = image }
        isSearching = false
        query = ""
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        relayout()
        assignHints()

        // 맨 앞 윈도우가 지금 쓰고 있는 윈도우라면, 바로 Enter 로 "직전 윈도우"에 갈 수 있게 그다음 것을 선택한다.
        if windows.count > 1, windows[0].pid == frontmostPID, windows[0].location == .visible {
            selectedID = windows[1].id
        } else {
            selectedID = windows.first?.id
        }
    }

    /// 열려 있는 상태에서 다른 디스플레이로 옮긴다. 화면 영역(contentRect 등)은 호출하는 쪽이 먼저 바꿔 둔다.
    func switchDisplay(to display: SwitcherDisplay) {
        self.display = display
        windows = filterToDisplay(allWindows)
        wallpaper = wallpapers[display.id]
        endSearch()
        relayout()
        assignHints()
        selectedID = windows.first?.id
    }

    private func filterToDisplay(_ list: [WindowInfo]) -> [WindowInfo] {
        guard let display, displays.count > 1 else { return list }
        return list.filter { SwitcherDisplay.owner(of: $0.frame, among: displays)?.id == display.id }
    }

    private func assignHints() {
        hints = [:]
        hintTargets = [:]
        for (window, key) in zip(items, HintKey.all) {
            hints[window.id] = key.label
            hintTargets[key.keyCode] = window.id
        }
    }

    /// 열린 뒤 도착한 정확한 목록을 반영한다. 구성이 그대로면 아무것도 건드리지 않는다 (힌트 글자가 바뀌면 안 되므로).
    func update(_ newWindows: [WindowInfo]) {
        allWindows = newWindows
        let filtered = filterToDisplay(newWindows)
        let same = filtered.count == windows.count
            && zip(filtered, windows).allSatisfy { $0.id == $1.id && $0.location == $1.location }
        guard !same else { return }
        windows = filtered
        relayout()
        if query.isEmpty { assignHints() }
    }

    private func relayout() {
        let tokens = query.split(separator: " ").map(String.init)
        let matching = tokens.isEmpty ? windows : windows.filter { window in
            let haystack = window.appName + " " + window.title
            return tokens.allSatisfy { haystack.localizedStandardContains($0) }
        }
        layout = MissionLayout.compute(matching, in: contentRect)
        let byID = Dictionary(matching.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        items = layout.order.compactMap { byID[$0] }
        if !items.contains(where: { $0.id == selectedID }) {
            selectedID = items.first?.id
        }
    }

    /// 펼치기 전 카드 위치: 실제 윈도우가 화면에 놓인 자리. 화면에 없는 윈도우는 nil.
    func sourceFrame(of window: WindowInfo) -> CGRect? {
        guard window.location == .visible else { return nil }
        return window.frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
    }

    func window(forHintKeyCode keyCode: UInt16) -> WindowInfo? {
        guard let id = hintTargets[keyCode] else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: 선택 이동

    func moveSelection(by delta: Int, wrap: Bool = true) {
        guard !items.isEmpty else { return }
        guard let index = items.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = items[0].id
            return
        }
        var next = index + delta
        if wrap {
            next = (next % items.count + items.count) % items.count
        } else if next < 0 || next >= items.count {
            return
        }
        selectedID = items[next].id
    }

    /// 위/아래 줄에서 가로 위치가 가장 가까운 윈도우로 이동한다.
    func moveVertically(_ direction: Int) {
        guard let id = selectedID, let from = layout.frames[id],
              let row = layout.rows.firstIndex(where: { $0.contains(id) }) else {
            selectedID = items.first?.id
            return
        }
        let target = row + direction
        guard layout.rows.indices.contains(target) else { return }
        selectedID = layout.rows[target].min { a, b in
            abs((layout.frames[a]?.midX ?? 0) - from.midX) < abs((layout.frames[b]?.midX ?? 0) - from.midX)
        }
    }

    func beginSearch() { isSearching = true }

    func endSearch() {
        isSearching = false
        query = ""
    }

    // MARK: 미리보기

    private var thumbnailTask: Task<Void, Never>?

    /// 선택기가 열려 있는 동안 각 윈도우의 실제 화면을 계속 다시 찍어서,
    /// Mission Control 처럼 지금 동작 중인 상태(재생 중인 영상, 진행 중인 터미널 등)가 그대로 보이게 한다.
    func startLiveThumbnails(maxPixelSize: CGFloat) {
        thumbnailTask?.cancel()
        firstRoundDone = false
        guard CGPreflightScreenCaptureAccess() else { firstRoundDone = true; return }
        let targets = windows
        thumbnailTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
                self?.firstRoundDone = true
                return
            }
            let shareable = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            if self?.wallpaper == nil { await self?.refreshWallpapers(from: content) }
            while !Task.isCancelled {
                await Self.captureRound(targets, shareable, maxPixelSize) { id, image in
                    guard !Task.isCancelled else { return }
                    self?.thumbnails[id] = image
                }
                self?.firstRoundDone = true
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private var firstRoundDone = false

    /// 첫 캡처가 끝날 때까지(최대 timeout) 기다린다. 펼치는 애니메이션이 실제 화면에서 시작되게 하기 위함.
    func waitForFirstThumbnails(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while !firstRoundDone, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 선택기가 닫혀 있을 때 미리 한 번 찍어 둔다. 다음에 열 때 첫 프레임부터 실제 화면이 보이게 하기 위함.
    func prewarmThumbnails(for targets: [WindowInfo], maxPixelSize: CGFloat) {
        guard thumbnailTask == nil, prewarmTask == nil, CGPreflightScreenCaptureAccess() else { return }
        prewarmTask = Task { [weak self] in
            defer { self?.prewarmTask = nil }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            let shareable = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            await self?.refreshWallpapers(from: content)
            await Self.captureRound(targets, shareable, maxPixelSize) { id, image in
                guard let self, self.thumbnailTask == nil else { return } // 열려 있으면 실시간 캡처가 담당
                self.thumbnails[id] = image
            }
            guard let self, self.thumbnailTask == nil else { return }
            let live = Set(targets.map(\.id))
            self.thumbnails = self.thumbnails.filter { live.contains($0.key) }
        }
    }

    private var prewarmTask: Task<Void, Never>?

    /// 모든 디스플레이의 바탕화면을 찍어 둔다. 디스플레이를 전환하면 그 화면의 것으로 바꿔 깐다.
    private func refreshWallpapers(from content: SCShareableContent) async {
        let targets = SwitcherDisplay.all()
        var fresh: [CGDirectDisplayID: CGImage] = [:]
        for target in targets {
            if let image = await Wallpaper.capture(from: content, screenFrame: target.frame, scale: target.scale) {
                fresh[target.id] = image
            }
        }
        wallpapers = fresh
        let shown = display ?? Wallpaper.mainScreen().flatMap { main in targets.first { $0.frame == main.frame } }
        if let shown, let image = fresh[shown.id] { wallpaper = image }
    }

    func stopLiveThumbnails() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }

    private static func captureRound(_ targets: [WindowInfo], _ shareable: [CGWindowID: SCWindow], _ maxPixelSize: CGFloat,
                                     deliver: @MainActor (CGWindowID, CGImage) -> Void) async {
        do {
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for window in targets {
                    guard let scWindow = shareable[window.id] else { continue }
                    group.addTask {
                        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                        let config = SCStreamConfiguration()
                        let scale = min(2, maxPixelSize / max(scWindow.frame.width, scWindow.frame.height, 1))
                        config.width = max(Int(scWindow.frame.width * scale), 1)
                        config.height = max(Int(scWindow.frame.height * scale), 1)
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        return (window.id, image)
                    }
                }
                for await (id, image) in group {
                    if let image { deliver(id, image) }
                }
            }
        }
    }
}
