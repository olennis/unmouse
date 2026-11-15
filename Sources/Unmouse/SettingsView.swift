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
                self.shortcutError = "⌘, ⌥, ⌃ 중 하나 이상과 함께 눌러 주세요."
                return nil
            }
            if self.shortcuts.contains(where: { $0.key != slot && $0.value == candidate }) {
                self.shortcutError = "\(candidate.display) 는 Unmouse 의 다른 기능에 이미 쓰이고 있습니다."
            } else if HotKeyCenter.shared.register(candidate, for: slot) {
                candidate.save(slot)
                self.shortcuts[slot] = candidate
                self.shortcutError = nil
            } else {
                self.shortcutError = "\(candidate.display) 는 다른 곳에서 사용 중이라 등록할 수 없습니다."
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
            loginError = "로그인 항목을 변경하지 못했습니다: \(error.localizedDescription)"
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
                Text("단축키")
            }

            Section {
                PermissionRow(
                    title: "손쉬운 사용",
                    detail: "다른 데스크탑·최소화된 윈도우와 윈도우 제목을 보여 주는 데 필요합니다.",
                    granted: model.accessibilityGranted,
                    shortcutKey: "1",
                    action: model.requestAccessibility
                )
                PermissionRow(
                    title: "화면 및 시스템 오디오 녹화",
                    detail: "윈도우 미리보기 이미지를 보여 주는 데 필요합니다. 없으면 앱 아이콘으로 표시됩니다. 허용 후 Unmouse 를 다시 실행해야 적용됩니다.",
                    granted: model.screenCaptureGranted,
                    shortcutKey: "2",
                    action: model.requestScreenCapture
                )
            } header: {
                Text("권한")
            } footer: {
                Text("시스템 설정 목록에서 Unmouse 를 켜 주세요. 화면 내용은 이 Mac 밖으로 전송되지 않습니다.")
            }

            Section {
                usageRow(model.shortcut(.scroll).keySymbols, "스크롤 모드 켜기 / 끄기")
                usageRow(["J", "K"], "아래 / 위로 스크롤 (↓ ↑ 도 가능, 누르고 있으면 계속)")
                usageRow(["D", "U"], "반 페이지 아래 / 위 (Space 는 한 페이지 아래)")
                usageRow(["G", "G"], "맨 위로")
                usageRow(["⇧", "G"], "맨 아래로")
                usageRow(["H", "L"], "왼쪽 / 오른쪽으로 스크롤")
                usageRow(["⇥"], "스크롤할 영역 바꾸기 (사이드바 ↔ 본문 등)")
                usageRow(["esc"], "끝내기")
            } header: {
                Text("키보드 스크롤")
            } footer: {
                Text("스크롤할 영역 가운데로 포인터가 이동합니다.")
            }

            Section("일반") {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin)) {
                    Text("로그인 시 자동 실행")
                    if let error = model.loginError { Text(error) }
                }
                Toggle("다른 데스크탑의 윈도우 포함", isOn: $includeOtherSpaces)
                Toggle("최소화되거나 가려진 윈도우 포함", isOn: $includeMinimized)
            }

            Section("윈도우 선택기") {
                usageRow(model.shortcut(.switcher).keySymbols, "열기 · 열린 상태에서는 다음 윈도우")
                usageRow(["A", "…", "Z"], "미리보기에 표시된 글자를 누르면 그 윈도우로 바로 이동")
                usageRow(["←", "↑", "↓", "→"], "선택 이동 (Tab / ⇧Tab 도 가능)")
                usageRow(["Space"], "선택한 윈도우로 이동 (↩ 도 가능)")
                usageRow(["/"], "앱 이름·윈도우 제목 검색 (검색 중에는 ↩ 로 선택)")
                usageRow(["esc"], "닫기")
            }

            Section {
                usageRow(model.shortcut(.hints).keySymbols, "지금 쓰는 윈도우의 버튼·링크·입력란에 글자 표시")
                usageRow(["A", "…", "Z"], "표시된 글자를 입력하면 그 자리를 클릭")
                usageRow(["⇧"], "마지막 글자를 ⇧ 와 함께 누르면 오른쪽 클릭")
                usageRow(["⌘"], "마지막 글자를 ⌘ 와 함께 누르면 ⌘ 클릭 (새 탭으로 열기 등)")
                usageRow(["⌫"], "한 글자 지우기")
                usageRow(["esc"], "취소")
            } header: {
                Text("클릭 힌트")
            } footer: {
                Text("손쉬운 사용 권한이 필요합니다. Chrome 등 일부 앱은 처음 한 번은 웹 페이지 요소가 덜 보일 수 있으니 다시 눌러 주세요.")
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
                Text("마우스 없이 키보드만으로 윈도우를 고르는 Mission Control")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button("Unmouse 종료") { NSApp.terminate(nil) }
            Spacer()
            Button("닫기") { model.onClose?() }
                .keyboardShortcut(.cancelAction)
            Button("윈도우 선택기 열어 보기") { model.onTryIt?() }
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
                        Text("새 단축키를 누르세요…")
                    } else {
                        HStack(spacing: 3) {
                            ForEach(model.shortcut(slot).keySymbols, id: \.self) { KeyCap($0) }
                        }
                    }
                }
                .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                if model.shortcut(slot) != slot.defaultShortcut {
                    Button("기본값") { model.resetShortcut(slot) }
                }
            }
        } label: {
            Text(slot.title)
            Text(recording ? "취소하려면 esc" : "⌘\(String(key).uppercased()) 를 누르고 새 단축키를 입력하면 변경됩니다.")
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
                Text("허용됨")
                    .foregroundStyle(.secondary)
            } else {
                Button("설정 열기  ⌘\(String(shortcutKey))", action: action)
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
