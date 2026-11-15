import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var shortcuts: [HotKeySlot: Shortcut] = Dictionary(uniqueKeysWithValues: HotKeySlot.allCases.map { ($0, Shortcut.load($0)) })
    @Published var recordingSlot: HotKeySlot?
    @Published var shortcutError: String?
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var screenCaptureGranted = CGPreflightScreenCaptureAccess()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    var onTryIt: (() -> Void)?
    var onClose: (() -> Void)?

    private var timer: Timer?
    private var monitor: Any?

    // MARK: 권한

    /// 시스템 설정에서 권한을 바꾸면 바로 반영되도록 창이 떠 있는 동안 주기적으로 확인한다.
    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        stopRecording()
    }

    private func refresh() {
        let ax = AXIsProcessTrusted()
        if ax != accessibilityGranted { accessibilityGranted = ax }
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenCaptureGranted { screenCaptureGranted = screen }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options) // 목록에 Unmouse 를 등록시킨다
        openPrivacyPane("Privacy_Accessibility")
    }

    func requestScreenCapture() {
        CGRequestScreenCaptureAccess()
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 단축키 녹화

    func toggleRecording(_ slot: HotKeySlot) {
        let wasRecording = recordingSlot == slot
        stopRecording()
        if !wasRecording { startRecording(slot) }
    }

    private func startRecording(_ slot: HotKeySlot) {
        recordingSlot = slot
        shortcutError = nil
        HotKeySlot.allCases.forEach(HotKeyCenter.shared.unregister) // 기존 단축키도 다시 지정할 수 있게 잠시 해제
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recordingSlot == slot else { return event }
            if event.keyCode == 53 { // esc
                self.stopRecording()
                return nil
            }
            let candidate = Shortcut(event: event)
            let hasStrongModifier = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            let isFunctionKey = KeyNames.name(for: candidate.keyCode).hasPrefix("F") && KeyNames.name(for: candidate.keyCode).count > 1
            guard hasStrongModifier || isFunctionKey else {
                self.shortcutError = String(localized: "Press it together with at least one of ⌘, ⌥, or ⌃.")
                return nil
            }
            if self.shortcuts.contains(where: { $0.key != slot && $0.value == candidate }) {
                self.shortcutError = String(localized: "\(candidate.display) is already used by another Unmouse feature.")
            } else if HotKeyCenter.shared.register(candidate, for: slot) {
                candidate.save(slot)
                self.shortcuts[slot] = candidate
                self.shortcutError = nil
            } else {
                self.shortcutError = String(localized: "\(candidate.display) is in use elsewhere and can’t be registered.")
            }
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        guard recordingSlot != nil || monitor != nil else { return }
        recordingSlot = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // 녹화 동안 해제해 둔 단축키를 되살린다
        for (slot, shortcut) in shortcuts { HotKeyCenter.shared.register(shortcut, for: slot) }
    }

    func resetShortcut(_ slot: HotKeySlot) {
        stopRecording()
        shortcuts[slot] = slot.defaultShortcut
        slot.defaultShortcut.save(slot)
        HotKeyCenter.shared.register(slot.defaultShortcut, for: slot)
        shortcutError = nil
    }

    func shortcut(_ slot: HotKeySlot) -> Shortcut { shortcuts[slot] ?? slot.defaultShortcut }

    // MARK: 로그인 항목

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = String(localized: "Couldn’t change the login item: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(Preferences.includeMinimized) private var includeMinimized = true
    @AppStorage(Preferences.includeOtherSpaces) private var includeOtherSpaces = true

    var body: some View {
        Form {
            Section {
                header
            }

            Section {
                shortcutRow(.switcher, key: "r")
                shortcutRow(.hints, key: "e")
                shortcutRow(.scroll, key: "d")
                if let error = model.shortcutError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } header: {
                Text("Shortcuts")
            }

            Section {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Needed to show windows on other desktops, minimized windows, and window titles.",
                    granted: model.accessibilityGranted,
                    shortcutKey: "1",
                    action: model.requestAccessibility
                )
                PermissionRow(
                    title: "Screen & System Audio Recording",
                    detail: "Needed to show window preview images. Without it, app icons are shown instead. Relaunch Unmouse after allowing it.",
                    granted: model.screenCaptureGranted,
                    shortcutKey: "2",
                    action: model.requestScreenCapture
                )
            } header: {
                Text("Permissions")
            } footer: {
                Text("Turn on Unmouse in the list in System Settings. Screen contents never leave this Mac.")
            }

            Section {
                usageRow(model.shortcut(.scroll).keySymbols, "Turn scroll mode on / off")
                usageRow(["J", "K"], "Scroll down / up (↓ ↑ also work; hold to keep scrolling)")
                usageRow(["D", "U"], "Half a page down / up (Space scrolls one page down)")
                usageRow(["G", "G"], "Jump to the top")
                usageRow(["⇧", "G"], "Jump to the bottom")
                usageRow(["H", "L"], "Scroll left / right")
                usageRow(["⇥"], "Switch the area being scrolled (sidebar ↔ content, etc.)")
                usageRow(["esc"], "Exit")
            } header: {
                Text("Keyboard Scroll")
            } footer: {
                Text("The pointer moves to the center of the area being scrolled.")
            }

            Section("General") {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin)) {
                    Text("Launch at login")
                    if let error = model.loginError { Text(error) }
                }
                Toggle("Include windows on other desktops", isOn: $includeOtherSpaces)
                Toggle("Include minimized or hidden windows", isOn: $includeMinimized)
            }

            Section("Window Switcher") {
                usageRow(model.shortcut(.switcher).keySymbols, "Open · while open, next window")
                usageRow(["A", "…", "Z"], "Press the letter on a preview to jump to that window")
                usageRow(["←", "↑", "↓", "→"], "Move the selection (Tab / ⇧Tab also work)")
                usageRow(["Space"], "Go to the selected window (↩ also works)")
                usageRow(["/"], "Search by app name or window title (↩ selects while searching)")
                usageRow(["esc"], "Close")
            }

            Section {
                usageRow(model.shortcut(.hints).keySymbols, "Label buttons, links, and text fields in the current window")
                usageRow(["A", "…", "Z"], "Type the letters shown to click that spot")
                usageRow(["⇧"], "Hold ⇧ with the last letter to right-click")
                usageRow(["⌘"], "Hold ⌘ with the last letter to ⌘-click (open in a new tab, etc.)")
                usageRow(["⌫"], "Delete one letter")
                usageRow(["esc"], "Cancel")
            } header: {
                Text("Click Hints")
            } footer: {
                Text("Requires the Accessibility permission. In some apps, such as Chrome, fewer web page elements may be labeled the first time; press the shortcut again.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { footer }
        .frame(width: 560, height: 760)
        .onAppear(perform: model.startPolling)
        .onDisappear(perform: model.stopPolling)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Unmouse")
                    .font(.title2.weight(.semibold))
                Text("Mission Control you drive with the keyboard, no mouse needed")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button("Quit Unmouse") { NSApp.terminate(nil) }
            Spacer()
            Button("Close") { model.onClose?() }
                .keyboardShortcut(.cancelAction)
            Button("Try the Window Switcher") { model.onTryIt?() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func shortcutRow(_ slot: HotKeySlot, key: Character) -> some View {
        let recording = model.recordingSlot == slot
        return LabeledContent {
            HStack(spacing: 8) {
                Button {
                    model.toggleRecording(slot)
                } label: {
                    if recording {
                        Text("Press a new shortcut…")
                    } else {
                        HStack(spacing: 3) {
                            ForEach(model.shortcut(slot).keySymbols, id: \.self) { KeyCap($0) }
                        }
                    }
                }
                .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                if model.shortcut(slot) != slot.defaultShortcut {
                    Button("Default") { model.resetShortcut(slot) }
                }
            }
        } label: {
            Text(slot.title)
            if recording { Text("Press esc to cancel") } else { Text("Press ⌘\(String(key).uppercased()), then type a new shortcut to change it.") }
        }
    }

    private func usageRow(_ keys: [String], _ text: LocalizedStringKey) -> some View {
        LabeledContent {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    if key == "…" { Text(key).foregroundStyle(.secondary) } else { KeyCap(key) }
                }
            }
        } label: {
            Text(text)
        }
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let shortcutKey: Character
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Text("Allowed")
                    .foregroundStyle(.secondary)
            } else {
                Button("Open Settings  ⌘\(String(shortcutKey))", action: action)
                    .keyboardShortcut(KeyEquivalent(shortcutKey), modifiers: .command)
            }
        } label: {
            Label {
                Text(title)
                Text(detail)
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}
