import AppKit
import ApplicationServices

// 공개 API로는 "다른 Space에 있는 특정 윈도우"를 나열하거나 앞으로 가져올 수 없어서
// AltTab·yabai 등이 쓰는 것과 같은 비공개 심볼을 사용한다.

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

/// 이 앱의 윈도우를 특정 Space 로 옮긴다 (데스크탑 전환 애니메이션에 선택기를 태우기 위해).
@_silgen_name("SLSMoveWindowsToManagedSpace")
func SLSMoveWindowsToManagedSpace(_ cid: Int32, _ windows: CFArray, _ space: UInt64)

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: Int32) -> UInt64

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

@_silgen_name("_SLPSSetFrontProcessWithOptions")
func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

// 시스템 설정 > 키보드 단축키 > Mission Control 의 항목 (79: 왼쪽 Space 로 이동, 81: 오른쪽 Space 로 이동)
@_silgen_name("CGSGetSymbolicHotKeyValue")
func CGSGetSymbolicHotKeyValue(_ hotKey: Int32, _ keyEquivalent: inout UInt16, _ virtualKeyCode: inout UInt16,
                               _ modifiers: inout UInt32) -> CGError

@_silgen_name("CGSIsSymbolicHotKeyEnabled")
func CGSIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool

@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> CGError

// MARK: - AX helpers

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var windowID: CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(self, &wid) == .success && wid != 0 ? wid : nil
    }
}

// MARK: - Spaces

struct SpaceMap {
    /// 지금 화면에 보이는 Space (디스플레이마다 하나)
    var visible: Set<Int> = []
    /// Space id → 표시용 이름 ("데스크탑 2", "전체 화면")
    var labels: [Int: String] = [:]
    /// Space id → 정렬용 순서
    var order: [Int: Int] = [:]
    /// 디스플레이마다 왼쪽 → 오른쪽 순서의 Space id
    var displaySpaces: [[Int]] = []

    /// active 와 같은 디스플레이에서 delta 칸 옆 Space. 끝이면 nil.
    func neighbor(of active: Int, by delta: Int) -> Int? {
        guard let spaces = displaySpaces.first(where: { $0.contains(active) }),
              let index = spaces.firstIndex(of: active), spaces.indices.contains(index + delta) else { return nil }
        return spaces[index + delta]
    }

    static func current() -> SpaceMap {
        var map = SpaceMap()
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        var desktopNumber = 0
        var index = 0
        for display in displays {
            if let cur = display["Current Space"] as? [String: Any], let id = spaceID(cur) {
                map.visible.insert(id)
            }
            var ids: [Int] = []
            defer { map.displaySpaces.append(ids) }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = spaceID(space) else { continue }
                ids.append(id)
                index += 1
                map.order[id] = index
                if (space["type"] as? Int ?? 0) == 0 {
                    desktopNumber += 1
                    map.labels[id] = L10n.format("Desktop %d", desktopNumber)
                } else {
                    map.labels[id] = L10n.text("Full Screen")
                }
            }
        }
        return map
    }

    private static func spaceID(_ dict: [String: Any]) -> Int? {
        (dict["id64"] as? Int) ?? (dict["ManagedSpaceID"] as? Int)
    }

    static func spaces(of wid: CGWindowID) -> [Int] {
        CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [Int(wid)] as CFArray) as? [Int] ?? []
    }
}
