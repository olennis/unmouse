import AppKit
import Carbon.HIToolbox

/// 트랙패드 세 손가락 좌우 쓸기처럼 옆 데스크탑(Space)으로 넘어간다.
///
/// 공개 API 로는 Space 를 바꿀 수 없고, 비공개 API 로 직접 바꾸면 Dock 이 상태를 놓쳐 화면이 꼬인다.
/// 그래서 시스템의 "왼쪽/오른쪽 Space 로 이동" 단축키(기본 ⌃← / ⌃→)를 대신 눌러 준다.
/// 사용자가 그 단축키를 바꿨어도 지금 설정된 조합을 읽어 보내고, 꺼져 있으면 보내는 동안만 잠깐 켠다.
/// 전환 애니메이션도 스와이프할 때와 똑같이 시스템이 그린다.
enum DesktopSwitcher {
    enum Direction {
        case left, right

        var symbolicHotKey: Int32 { self == .left ? 79 : 81 }
        var fallbackKeyCode: UInt16 { UInt16(self == .left ? kVK_LeftArrow : kVK_RightArrow) }
    }

    /// 키 이벤트를 보내려면 손쉬운 사용 권한이 필요하다. 권한이 없으면 false.
    @discardableResult
    static func move(_ direction: Direction) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let hotKey = direction.symbolicHotKey

        var character: UInt16 = 0
        var keyCode: UInt16 = 0
        var modifiers: UInt32 = 0
        // 기본값: ⌃ + 화살표 (화살표 키 이벤트에는 fn 플래그가 붙는다)
        var flags: CGEventFlags = [.maskControl, .maskSecondaryFn]
        if CGSGetSymbolicHotKeyValue(hotKey, &character, &keyCode, &modifiers) == .success, keyCode != 0xFFFF {
            flags = CGEventFlags(rawValue: UInt64(modifiers))
        } else {
            keyCode = direction.fallbackKeyCode
        }

        let wasEnabled = CGSIsSymbolicHotKeyEnabled(hotKey)
        if !wasEnabled { _ = CGSSetSymbolicHotKeyEnabled(hotKey, true) }

        // 사용자가 누르고 있는 Unmouse 단축키의 수정 키(⌘ 등)가 섞이지 않도록 플래그를 직접 지정한다.
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }

        if !wasEnabled {
            // WindowServer 가 이벤트를 처리한 뒤에 원래대로 끈다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                _ = CGSSetSymbolicHotKeyEnabled(hotKey, false)
            }
        }
        return true
    }
}
