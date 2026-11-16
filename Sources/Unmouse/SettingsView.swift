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
                self.shortcutError = L10n.text("Include at least one modifier: ⌘, ⌥, or ⌃.")
                return nil
            }
            if self.shortcuts.contains(where: { $0.key != slot && $0.value == candidate }) {
                self.shortcutError = L10n.format("%@ is already assigned to another Unmouse feature.", candidate.display)
            } else if HotKeyCenter.shared.register(candidate, for: slot) {
                candidate.save(slot)
                self.shortcuts[slot] = candidate
                self.shortcutError = nil
            } else {
                self.shortcutError = L10n.format("%@ is in use elsewhere and could not be registered.", candidate.display)
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
            loginError = L10n.format("Could not change login item: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(Preferences.includeMinimized) private var includeMinimized = true
    @AppStorage(Preferences.includeOtherSpaces) private var includeOtherSpaces = true
    @AppStorage(Preferences.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some View {
        Form {
            Section {
                header
            }

            Section {
                shortcutRow(.switcher, key: "r")
                shortcutRow(.nextDisplay, key: "s")
                shortcutRow(.previousDesktop, key: "[")
                shortcutRow(.nextDesktop, key: "]")
                shortcutRow(.hints, key: "e")
                shortcutRow(.scroll, key: "d")
                if let error = model.shortcutError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } header: {
                Text(L10n.text("Shortcuts"))
            }

            Section {
                PermissionRow(
                    title: L10n.text("Accessibility"),
                    detail: L10n.text("Required to show windows on other desktops, minimized windows, and window titles."),
                    granted: model.accessibilityGranted,
                    shortcutKey: "1",
                    action: model.requestAccessibility
                )
                PermissionRow(
                    title: L10n.text("Screen & System Audio Recording"),
                    detail: L10n.text("Required for window previews. Without it, app icons are shown. Relaunch Unmouse after granting permission."),
                    granted: model.screenCaptureGranted,
                    shortcutKey: "2",
                    action: model.requestScreenCapture
                )
            } header: {
                Text(L10n.text("Permissions"))
            } footer: {
                Text(L10n.text("Enable Unmouse in System Settings. Screen contents never leave this Mac."))
            }

            Section {
                usageRow(model.shortcut(.scroll).keySymbols, L10n.text("Toggle scroll mode"))
                usageRow(["J", "K"], L10n.text("Scroll down / up (also ↓ ↑; hold to keep scrolling)"))
                usageRow(["D", "U"], L10n.text("Half page down / up (Space scrolls a full page down)"))
                usageRow(["G", "G"], L10n.text("Go to top"))
                usageRow(["⇧", "G"], L10n.text("Go to bottom"))
                usageRow(["H", "L"], L10n.text("Scroll left / right"))
                usageRow(["⇥"], L10n.text("Switch scroll area (e.g. sidebar ↔ content)"))
                usageRow(["esc"], L10n.text("Exit"))
            } header: {
                Text(L10n.text("Keyboard Scroll"))
            } footer: {
                Text(L10n.text("The pointer moves to the center of the scroll area."))
            }

            Section(L10n.text("General")) {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin)) {
                    Text(L10n.text("Launch at login"))
                    if let error = model.loginError { Text(error) }
                }
                Toggle(isOn: $showMenuBarIcon) {
                    Text(L10n.text("Show icon in menu bar"))
                    if !showMenuBarIcon {
                        Text(L10n.text("Unmouse keeps running. To open Settings, launch Unmouse again from Spotlight."))
                    }
                }
                Toggle(L10n.text("Include windows on other desktops"), isOn: $includeOtherSpaces)
                Toggle(L10n.text("Include minimized and hidden windows"), isOn: $includeMinimized)
            }

            Section(L10n.text("Window Switcher")) {
                usageRow(model.shortcut(.switcher).keySymbols, L10n.text("Open · when open, select the next window"))
                usageRow(["A", "…", "Z"], L10n.text("Press the letter on a preview to switch to that window"))
                usageRow(["←", "↑", "↓", "→"], L10n.text("Move selection (also Tab / ⇧Tab)"))
                usageRow(["Space"], L10n.text("Switch to selected window (also ↩)"))
                usageRow(["/"], L10n.text("Search by app or window title (↩ to select while searching)"))
                usageRow(["`"], L10n.text("Show windows on the next display (⇧` for the previous one)"))
                usageRow(["esc"], L10n.text("Close"))
            }

            Section {
                usageRow(model.shortcut(.hints).keySymbols, L10n.text("Label buttons, links, and text fields in the current window"))
                usageRow(["A", "…", "Z"], L10n.text("Type the label to click that spot"))
                usageRow(["⇧"], L10n.text("Hold ⇧ with the last letter to right-click"))
                usageRow(["⌘"], L10n.text("Hold ⌘ with the last letter to ⌘-click (e.g. open in a new tab)"))
                usageRow(["⌫"], L10n.text("Delete one letter"))
                usageRow(["esc"], L10n.text("Cancel"))
            } header: {
                Text(L10n.text("Click Hints"))
            } footer: {
                Text(L10n.text("Requires Accessibility permission. In apps such as Chrome, press the shortcut again if some web page elements are missing on the first try."))
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
                Text(L10n.text("Mission Control for choosing windows with just your keyboard"))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button(L10n.text("Quit Unmouse")) { NSApp.terminate(nil) }
            Spacer()
            Button(L10n.text("Close")) { model.onClose?() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.text("Try Window Switcher")) { model.onTryIt?() }
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
                        Text(L10n.text("Press a new shortcut…"))
                    } else {
                        HStack(spacing: 3) {
                            ForEach(model.shortcut(slot).keySymbols, id: \.self) { KeyCap($0) }
                        }
                    }
                }
                .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                if model.shortcut(slot) != slot.defaultShortcut {
                    Button(L10n.text("Reset")) { model.resetShortcut(slot) }
                }
            }
        } label: {
            Text(slot.title)
            Text(recording ? L10n.text("esc to cancel") : L10n.format("Press ⌘%@, then enter a new shortcut to change it.", String(key).uppercased()))
        }
    }

    private func usageRow(_ keys: [String], _ text: String) -> some View {
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
    let title: String
    let detail: String
    let granted: Bool
    let shortcutKey: Character
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Text(L10n.text("Allowed"))
                    .foregroundStyle(.secondary)
            } else {
                Button(L10n.format("Open Settings  ⌘%@", String(shortcutKey)), action: action)
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
