import AppKit
import ApplicationServices

struct WindowInfo: Identifiable {
    enum Location: Equatable {
        case visible            // 현재 화면에 보임
        case otherSpace(String) // 다른 데스크탑 / 전체 화면 Space
        case minimized
        case hidden             // ⌘H 로 가려진 앱
    }

    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage?
    let frame: CGRect
    let location: Location
    let ax: AXUIElement?
    /// 정렬 키 (작을수록 앞)
    let rank: Int

    var aspectRatio: CGFloat {
        guard frame.height > 0 else { return 1.6 }
        return min(max(frame.width / frame.height, 0.5), 3.0)
    }
}

/// 열려 있는 모든 윈도우를 수집한다.
/// - 손쉬운 사용 권한이 있으면: 모든 Space + 최소화 + 가려진 앱의 윈도우 (제목 포함)
/// - 없으면: 현재 화면에 보이는 윈도우만
final class WindowCatalog {
    static let shared = WindowCatalog()

    private let lock = NSLock()
    /// 다른 Space의 윈도우는 AX 요소를 찾는 비용이 커서 캐시해 둔다.
    private var axCache: [CGWindowID: AXUIElement] = [:]

    private struct CGEntry {
        let wid: CGWindowID
        let pid: pid_t
        let ownerName: String
        let name: String?
        let frame: CGRect
        let onScreen: Bool
        let zIndex: Int
    }

    /// 마지막 전체 수집 결과. 단축키를 누른 순간에는 이것을 바탕으로 즉시 목록을 만든다.
    private var cache: [WindowInfo]?

    /// 전체 수집(수십 ms, AX 호출 포함)을 하고 결과를 캐시에 넣는다. 백그라운드 스레드에서 호출한다.
    @discardableResult
    func refresh() -> [WindowInfo] {
        let all = list(includeMinimized: true, includeOtherSpaces: true)
        lock.lock(); cache = all; lock.unlock()
        return all
    }

    /// 지연 없는 목록: 캐시해 둔 윈도우 정보에 "지금 이 순간"의 위치·앞뒤 순서만 다시 입힌다 (1~2ms).
    /// 캐시가 아직 없으면 nil.
    func quickList() -> [WindowInfo]? {
        lock.lock(); let cached = cache; lock.unlock()
        guard let cached else { return nil }
        let entries = Dictionary(cgEntries().map { ($0.wid, $0) }, uniquingKeysWith: { a, _ in a })
        return cached.compactMap { w -> WindowInfo? in
            guard let e = entries[w.id] else { return nil } // 그사이 닫힌 윈도우
            var location = w.location
            var rank = w.rank
            if e.onScreen {
                location = .visible
                rank = e.zIndex
            } else if w.location == .visible {
                // 그사이 다른 데스크탑으로 갔거나 최소화됨. 정확한 상태는 뒤따르는 전체 수집이 바로잡는다.
                location = .otherSpace(L10n.text("Other Desktop"))
                rank = 1_000_000 + Int(w.id % 1000)
            }
            return WindowInfo(id: w.id, pid: w.pid, appName: w.appName, title: w.title, icon: w.icon,
                              frame: e.frame, location: location, ax: w.ax, rank: rank)
        }
    }

    static func applyPreferences(_ windows: [WindowInfo]) -> [WindowInfo] {
        let defaults = UserDefaults.standard
        let includeMinimized = defaults.bool(forKey: Preferences.includeMinimized)
        let includeOtherSpaces = defaults.bool(forKey: Preferences.includeOtherSpaces)
        return windows.filter { window in
            switch window.location {
            case .visible: return true
            case .otherSpace: return includeOtherSpaces
            case .minimized, .hidden: return includeMinimized
            }
        }.sorted { $0.rank < $1.rank }
    }

    func list(includeMinimized: Bool, includeOtherSpaces: Bool) -> [WindowInfo] {
        let entries = cgEntries()
        let trusted = AXIsProcessTrusted()
        let spaces = SpaceMap.current()
        let myPID = getpid()

        let byPID = Dictionary(grouping: entries.filter { $0.pid != myPID }, by: \.pid)
        let pids = Array(byPID.keys)
        var results = [[WindowInfo]](repeating: [], count: pids.count)

        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let pid = pids[i]
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy != .prohibited else { return }
            let found = trusted
                ? windowsWithAX(app: app, entries: byPID[pid] ?? [], spaces: spaces)
                : windowsWithoutAX(app: app, entries: byPID[pid] ?? [])
            lock.lock(); results[i] = found; lock.unlock()
        }

        let liveIDs = Set(entries.map(\.wid))
        lock.lock()
        axCache = axCache.filter { liveIDs.contains($0.key) }
        lock.unlock()

        return results.flatMap { $0 }
            .filter { window in
                switch window.location {
                case .visible: return true
                case .otherSpace: return includeOtherSpaces
                case .minimized, .hidden: return includeMinimized
                }
            }
            .sorted { $0.rank < $1.rank }
    }

    // MARK: - CoreGraphics

    private func cgEntries() -> [CGEntry] {
        // 화면에 보이는 윈도우 목록은 앞→뒤 순서로 온다. 이 순서를 최근 사용 순서로 쓴다.
        let onScreenList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var zOrder: [CGWindowID: Int] = [:]
        for (i, w) in onScreenList.enumerated() {
            if let wid = w[kCGWindowNumber as String] as? CGWindowID { zOrder[wid] = i }
        }

        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= 100, frame.height >= 60
            else { return nil }
            return CGEntry(
                wid: wid, pid: pid,
                ownerName: w[kCGWindowOwnerName as String] as? String ?? "",
                name: w[kCGWindowName as String] as? String,
                frame: frame,
                onScreen: zOrder[wid] != nil,
                zIndex: zOrder[wid] ?? Int.max
            )
        }
    }

    // MARK: - 권한 없음: 보이는 윈도우만

    private func windowsWithoutAX(app: NSRunningApplication, entries: [CGEntry]) -> [WindowInfo] {
        guard app.activationPolicy == .regular else { return [] }
        return entries.filter { $0.onScreen && $0.frame.height >= 100 }.map { e in
            WindowInfo(id: e.wid, pid: e.pid, appName: app.localizedName ?? e.ownerName,
                       title: e.name ?? "", icon: app.icon, frame: e.frame,
                       location: .visible, ax: nil, rank: e.zIndex)
        }
    }

    // MARK: - 손쉬운 사용 권한 있음

    private func windowsWithAX(app: NSRunningApplication, entries: [CGEntry], spaces: SpaceMap) -> [WindowInfo] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3) // 응답 없는 앱 때문에 전체가 멈추지 않도록

        var elements: [CGWindowID: AXUIElement] = [:]
        let axWindows: [AXUIElement] = appElement.attribute(kAXWindowsAttribute) ?? []
        for element in axWindows {
            if let wid = element.windowID { elements[wid] = element }
        }

        // kAXWindows 는 현재 Space의 윈도우만 돌려준다.
        // 다른 Space에 있는 윈도우는 캐시 → 무차별 탐색 순으로 AX 요소를 찾는다.
        let known = Set(entries.map(\.wid))
        var missing = Set<CGWindowID>()
        var spacesByWindow: [CGWindowID: [Int]] = [:]
        for entry in entries where elements[entry.wid] == nil && !entry.onScreen {
            let windowSpaces = SpaceMap.spaces(of: entry.wid)
            spacesByWindow[entry.wid] = windowSpaces
            // Space가 없거나 현재 Space뿐인데 AX 목록에 없다 → 탭이나 보조 윈도우
            guard !windowSpaces.isEmpty, !windowSpaces.allSatisfy(spaces.visible.contains) else { continue }
            lock.lock(); let cached = axCache[entry.wid]; lock.unlock()
            if let cached { elements[entry.wid] = cached } else { missing.insert(entry.wid) }
        }
        if !missing.isEmpty {
            for (wid, element) in bruteForceWindows(pid: pid, wanted: missing) {
                elements[wid] = element
                lock.lock(); axCache[wid] = element; lock.unlock()
            }
        }

        var windows: [WindowInfo] = []
        for entry in entries where known.contains(entry.wid) {
            guard let element = elements[entry.wid] else { continue }
            let subrole: String = element.attribute(kAXSubroleAttribute) ?? ""
            let title: String = element.attribute(kAXTitleAttribute) ?? entry.name ?? ""
            let isStandard = subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
            // 일부 앱(Electron, Java 등)은 subrole 을 채우지 않는다.
            let looksLikeWindow = subrole.isEmpty && !title.isEmpty && entry.frame.width >= 200 && entry.frame.height >= 150
            guard isStandard || looksLikeWindow else { continue }
            guard app.activationPolicy == .regular || entry.onScreen else { continue }

            let minimized: Bool = element.attribute(kAXMinimizedAttribute) ?? false
            let location: WindowInfo.Location
            var rank: Int
            if entry.onScreen {
                location = .visible
                rank = entry.zIndex
            } else if minimized {
                location = .minimized
                rank = 3_000_000
            } else if app.isHidden {
                location = .hidden
                rank = 2_000_000
            } else {
                let windowSpaces = spacesByWindow[entry.wid] ?? SpaceMap.spaces(of: entry.wid)
                if let other = windowSpaces.first(where: { !spaces.visible.contains($0) }) {
                    location = .otherSpace(spaces.labels[other] ?? L10n.text("Other Desktop"))
                    rank = 1_000_000 + (spaces.order[other] ?? 0) * 1000
                } else {
                    continue // 현재 Space에 있는데 보이지 않고 최소화도 아님 → 윈도우 탭
                }
            }
            rank += entry.onScreen ? 0 : Int(entry.wid % 1000)
            windows.append(WindowInfo(id: entry.wid, pid: pid, appName: app.localizedName ?? entry.ownerName,
                                      title: title, icon: app.icon, frame: entry.frame,
                                      location: location, ax: element, rank: rank))
        }
        return windows
    }

    /// AX 요소 ID를 순서대로 대입해 보며 다른 Space에 있는 윈도우의 AX 요소를 찾는다 (AltTab 방식).
    private func bruteForceWindows(pid: pid_t, wanted: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })

        var found: [CGWindowID: AXUIElement] = [:]
        let deadline = DispatchTime.now() + .milliseconds(120)
        for axID: UInt64 in 0..<1000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: axID) { Data($0) })
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.1)
            if let wid = element.windowID, wanted.contains(wid) {
                found[wid] = element
                if found.count == wanted.count { break }
            }
            if DispatchTime.now() > deadline { break }
        }
        return found
    }
}

// MARK: - 윈도우 활성화

enum WindowFocuser {
    static func focus(_ window: WindowInfo) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }
        if window.location == .minimized, let ax = window.ax {
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        var psn = ProcessSerialNumber()
        if GetProcessForPID(window.pid, &psn) == noErr {
            // 윈도우가 다른 Space에 있으면 그 Space로 전환까지 해 준다.
            _ = _SLPSSetFrontProcessWithOptions(&psn, window.id, 0x200 /* userGenerated */)
            makeKeyWindow(&psn, window.id)
        } else {
            app?.activate()
        }

        if let ax = window.ax {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// 대상 윈도우가 키 입력을 받도록 WindowServer 이벤트를 직접 보낸다.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
        var wid = wid
        for phase: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x08] = phase
            bytes[0x3a] = 0x10
            memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
            memset(&bytes[0x20], 0xff, 0x10)
            _ = bytes.withUnsafeMutableBufferPointer { SLPSPostEventRecordTo(&psn, $0.baseAddress!) }
        }
    }
}
