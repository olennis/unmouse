import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// 기본값: ⌥Tab
    static let `default` = Shortcut(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(event: NSEvent) {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
    }

    var modifierSymbols: [String] {
        var s: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { s.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { s.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { s.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { s.append("⌘") }
        return s
    }

    var keySymbols: [String] { modifierSymbols + [KeyNames.name(for: keyCode)] }
    var display: String { keySymbols.joined() }

    // MARK: 저장

    static func load(_ slot: HotKeySlot = .switcher) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: slot.defaultsKey),
              let value = try? JSONDecoder().decode(Shortcut.self, from: data) else { return slot.defaultShortcut }
        return value
    }

    func save(_ slot: HotKeySlot = .switcher) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: slot.defaultsKey)
        }
    }
}

/// Unmouse 가 쓰는 전역 단축키 종류
enum HotKeySlot: UInt32, CaseIterable {
    case switcher = 1   // 윈도우 선택기
    case hints = 2      // 클릭 힌트
    case scroll = 3     // 키보드 스크롤

    var defaultsKey: String {
        switch self {
        case .switcher: "shortcut"
        case .hints: "hintShortcut"
        case .scroll: "scrollShortcut"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .switcher: .default                                                        // ⌥Tab
        case .hints: Shortcut(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(optionKey)) // ⌥F
        case .scroll: Shortcut(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(optionKey)) // ⌥J
        }
    }

    var title: String {
        switch self {
        case .switcher: L10n.text("Open Window Switcher")
        case .hints: L10n.text("Show Click Hints")
        case .scroll: L10n.text("Keyboard Scroll Mode")
        }
    }
}

enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Tab: "⇥", kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func name(for keyCode: UInt32) -> String {
        if let s = special[Int(keyCode)] { return s }
        // 한글 입력 상태에서도 영문 키 이름이 나오도록 ASCII 배열 기준으로 변환한다.
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { ptr -> OSStatus in
            UCKeyTranslate(ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// 시스템 전역 단축키 (Carbon). 별도 권한이 필요 없다.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var handlers: [HotKeySlot: () -> Void] = [:]
    private(set) var current: [HotKeySlot: Shortcut] = [:]
    private var refs: [HotKeySlot: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    @discardableResult
    func register(_ shortcut: Shortcut, for slot: HotKeySlot) -> Bool {
        installHandlerIfNeeded()
        unregister(slot)
        let id = EventHotKeyID(signature: OSType(0x4B50_4C54) /* 'KPLT' */, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[slot] = ref
        current[slot] = shortcut
        return true
    }

    func unregister(_ slot: HotKeySlot) {
        if let ref = refs[slot] { UnregisterEventHotKey(ref) }
        refs[slot] = nil
        current[slot] = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let slot = HotKeySlot(rawValue: id.id) {
                DispatchQueue.main.async { HotKeyCenter.shared.handlers[slot]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
