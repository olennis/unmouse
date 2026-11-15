import AppKit
import SwiftUI

/// 화면 가장자리에서 카드 영역까지의 여백 (검색 바·키 안내 자리)
enum SwitcherInsets {
    static let top: CGFloat = 118     // 검색 바 + 안내 문구 자리
    static let bottom: CGFloat = 76   // 키 안내 자리
    static let side: CGFloat = 64

    /// 메뉴 막대·Dock 을 피한 영역(safe) 안에서 카드를 펼칠 영역. 패널 좌표계(왼쪽 위 원점).
    static func contentRect(size: CGSize, safe: EdgeInsets) -> CGRect {
        CGRect(x: safe.leading + side, y: safe.top + top,
               width: size.width - safe.leading - safe.trailing - side * 2,
               height: size.height - safe.top - safe.bottom - top - bottom)
    }
}

// MARK: - 메인 뷰

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    var onActivate: (WindowInfo) -> Void = { _ in }
    var onClose: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let wallpaper = model.wallpaper {
                    // Mission Control 처럼 바탕화면이 깔리고 그 위에 윈도우가 펼쳐진다.
                    Image(decorative: wallpaper, scale: 1)
                        .resizable()
                    Color.black.opacity(0.22)
                } else {
                    VisualEffectBackground()
                    Color.black.opacity(0.38)
                }
            }
            .opacity(model.expanded ? 1 : 0)
            // 배경은 카드보다 빨리 깔려서, 줄어드는 카드 뒤로 실제 윈도우가 비치는 시간을 줄인다.
            .animation(.easeOut(duration: 0.12), value: model.expanded)
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)

            cards

            chrome
                .opacity(model.expanded ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        // 검색으로 윈도우가 걸러지면 남은 카드가 새 자리로 미끄러진다.
        .animation(.snappy(duration: 0.28), value: model.query)
    }

    private var cards: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(model.items.enumerated()), id: \.element.id) { _, window in
                let target = model.layout.frames[window.id] ?? .zero
                let source = model.sourceFrame(of: window)
                // 접힌 상태: 실제 윈도우 자리. 화면에 없는 윈도우는 제자리에서 살짝 작게 사라진다.
                let frame = model.expanded ? target : (source ?? target.insetBy(dx: target.width * 0.06, dy: target.height * 0.06))
                let isSelected = window.id == model.selectedID

                WindowCard(
                    window: window,
                    thumbnail: model.thumbnails[window.id],
                    hint: model.isSearching || !model.expanded ? nil : model.hints[window.id],
                    isSelected: isSelected && model.expanded
                )
                .frame(width: frame.width, height: frame.height)
                .overlay(alignment: .bottom) {
                    WindowLabel(window: window, isSelected: isSelected)
                        .frame(width: max(frame.width + MissionLayout.hGap - 8, 120))
                        .offset(y: MissionLayout.labelBlock - 4)
                        .opacity(model.expanded ? 1 : 0)
                }
                .position(x: frame.midX, y: frame.midY)
                .opacity(model.expanded || source != nil ? 1 : 0)
                // 실제 화면과 같은 앞뒤 순서: 지금 쓰던 윈도우가 맨 위에서 줄어든다.
                // 닫힐 때만 이동할 윈도우를 맨 위로 올린다.
                .zIndex(window.id == model.raisedID ? 2_000_000 : Double(1_000_000 - min(window.rank, 999_999)))
                .onTapGesture { onActivate(window) }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            SearchBar(model: model)
                .padding(.top, 16)
            if !model.accessibilityGranted {
                PermissionBanner(message: L10n.text("Only windows on the current screen are shown without Accessibility permission."))
                    .padding(.top, 12)
            } else if !model.screenCaptureGranted {
                PermissionBanner(message: L10n.text("App icons are shown instead of previews without Screen Recording permission."))
                    .padding(.top, 12)
            }
            Spacer(minLength: 0)
            if model.items.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? L10n.text("No Open Windows") : L10n.format("No Results for “%@”", model.query),
                    systemImage: model.query.isEmpty ? "macwindow" : "magnifyingglass",
                    description: Text(model.query.isEmpty ? L10n.text("There are no windows to show.") : L10n.text("Try searching by app name or window title."))
                )
                Spacer(minLength: 0)
            }
            LegendBar(isSearching: model.isSearching)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(model.safeInsets) // 메뉴 막대와 Dock 은 그대로 보이므로 그 안쪽에 배치
    }
}

// MARK: - 윈도우 카드

struct WindowCard: View {
    let window: WindowInfo
    let thumbnail: CGImage?
    let hint: String?
    let isSelected: Bool

    private let corner = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
            } else {
                corner
                    .fill(Color(white: 0.24))
                    .overlay {
                        if let icon = window.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 72, maxHeight: 72)
                                .padding(12)
                        }
                    }
            }
        }
        .clipShape(corner)
        .overlay {
            corner.strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.18),
                                lineWidth: isSelected ? 4 : 1)
        }
        .overlay(alignment: .topLeading) {
            if let hint {
                Text(hint)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                    }
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.55 : 0.35), radius: isSelected ? 24 : 12, y: isSelected ? 10 : 5)
        .scaleEffect(isSelected ? 1.035 : 1)
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.16), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.appName) \(window.title)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct WindowLabel: View {
    let window: WindowInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            Text(window.appName)
                .fontWeight(.semibold)
                .layoutPriority(1)
            if !window.title.isEmpty, window.title != window.appName {
                Text(window.title)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            if let badge {
                Label(badge.text, systemImage: badge.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.16), in: Capsule())
                    .fixedSize()
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: Capsule())
        .shadow(color: .black.opacity(isSelected ? 0 : 0.7), radius: 3, y: 1) // 밝은 바탕화면 위에서도 읽히도록
        .animation(.snappy(duration: 0.16), value: isSelected)
    }

    private var badge: (text: String, symbol: String)? {
        switch window.location {
        case .visible: nil
        case .otherSpace(let name): (name, "rectangle.on.rectangle")
        case .minimized: (L10n.text("Minimized"), "arrow.down.right.and.arrow.up.left")
        case .hidden: (L10n.text("Hidden"), "eye.slash")
        }
    }
}

// MARK: - 상단 검색 바

struct SearchBar: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                SearchField(text: $model.query, isActive: model.isSearching)
                    .opacity(model.isSearching ? 1 : 0)
                if !model.isSearching {
                    Text(L10n.text("Search windows"))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.isSearching {
                Text(L10n.format("Windows: %d", model.items.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                KeyCap("/")
            }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 18)
        .frame(width: 480, height: 46)
        .glassEffect(.regular, in: .capsule)
    }
}

/// 한글 조합 입력이 제대로 되도록 실제 NSTextField 를 쓴다.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.textColor = .white
        field.placeholderString = L10n.text("App name or window title")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        let active = isActive
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            let editing = field.currentEditor() != nil
            if active, !editing {
                window.makeFirstResponder(field)
            } else if !active, editing {
                window.makeFirstResponder(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

// MARK: - 하단 키 안내

struct LegendBar: View {
    let isSearching: Bool

    var body: some View {
        HStack(spacing: 18) {
            if isSearching {
                item(["←", "↑", "↓", "→"], L10n.text("Navigate"))
                item(["↩"], L10n.text("Select"))
                item(["esc"], L10n.text("End search"))
            } else {
                item(["A", "–", "Z"], L10n.text("Jump to window"))
                item(["←", "↑", "↓", "→"], L10n.text("Navigate"))
                item(["Space"], L10n.text("Select"))
                item(["/"], L10n.text("Search"))
                item(["⌘", ","], L10n.text("Settings"))
                item(["esc"], L10n.text("Close"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .frame(height: 42)
        .glassEffect(.regular, in: .capsule)
    }

    private func item(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                if key == "–" { Text(key).foregroundStyle(.secondary) } else { KeyCap(key) }
            }
            Text(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }
}

struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.14), lineWidth: 1)
            }
    }
}

struct PermissionBanner: View {
    let message: String
    var body: some View {
        Label {
            Text(L10n.format("%@  Open Settings with ⌘, to grant permission.", message))
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - 배경 블러

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
