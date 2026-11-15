import AppKit
import SwiftUI

/// 개발용: 목업 윈도우 위에 실제 UI 를 그려 README 용 예시 화면을 만든다.  Unmouse --demo <디렉터리>
/// 권한이 필요 없고, 실제 화면 내용이 들어가지 않는다.
@MainActor
enum Demo {
    static let screen = CGSize(width: 1728, height: 1117)
    /// 힌트·스크롤 예시에서 목업 문서 윈도우가 놓이는 자리
    static let documentFrame = CGRect(x: 274, y: 130, width: MockDocument.size.width, height: MockDocument.size.height)

    static func run(outputDirectory: String) {
        Preferences.registerDefaults()
        let wallpaper = Snapshot.image(of: MockWallpaper(), size: screen)

        // 윈도우 선택기
        let mocks: [(app: String, title: String, path: String, frame: CGRect, location: WindowInfo.Location, view: AnyView)] = [
            ("Safari", "Unmouse User Guide", "/Applications/Safari.app",
             CGRect(x: 90, y: 70, width: 1180, height: 760), .visible, AnyView(MockDocument())),
            ("Terminal", "unmouse — zsh", "/System/Applications/Utilities/Terminal.app",
             CGRect(x: 940, y: 560, width: 720, height: 460), .visible, AnyView(MockTerminal())),
            ("Notes", "Meeting Notes", "/System/Applications/Notes.app",
             CGRect(x: 60, y: 600, width: 620, height: 440), .visible, AnyView(MockNotes())),
            ("Calendar", "", "/System/Applications/Calendar.app",
             CGRect(x: 0, y: 0, width: 980, height: 660), .otherSpace("Desktop 2"), AnyView(MockCalendar())),
            ("Finder", "Documents", "/System/Library/CoreServices/Finder.app",
             CGRect(x: 0, y: 0, width: 860, height: 540), .minimized, AnyView(MockFinder())),
        ]
        var windows: [WindowInfo] = []
        var thumbnails: [CGWindowID: CGImage] = [:]
        for (index, mock) in mocks.enumerated() {
            let id = CGWindowID(index + 1)
            windows.append(WindowInfo(id: id, pid: pid_t(1000 + index), appName: mock.app, title: mock.title,
                                      icon: NSWorkspace.shared.icon(forFile: mock.path), frame: mock.frame,
                                      location: mock.location, ax: nil, rank: index))
            thumbnails[id] = Snapshot.image(of: mock.view, size: mock.frame.size)
        }

        let model = SwitcherModel()
        model.safeInsets = EdgeInsets(top: 30, leading: 0, bottom: 20, trailing: 0)
        model.contentRect = SwitcherInsets.contentRect(size: screen, safe: model.safeInsets)
        model.load(windows, frontmostPID: windows.first?.pid)
        model.accessibilityGranted = true
        model.screenCaptureGranted = true
        model.thumbnails = thumbnails
        model.wallpaper = wallpaper
        model.expanded = true
        Snapshot.render(SwitcherView(model: model), size: screen, to: "\(outputDirectory)/switcher.png")

        model.beginSearch()
        model.query = "un"
        Snapshot.render(SwitcherView(model: model), size: screen, to: "\(outputDirectory)/search.png")

        // 클릭 힌트
        let frames = MockDocument.clickable.map { $0.offsetBy(dx: documentFrame.minX, dy: documentFrame.minY) }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        let hintModel = HintModel()
        hintModel.targets = zip(frames, HintScanner.labels(count: frames.count)).enumerated().map {
            HintTarget(id: $0, frame: $1.0, clickPoint: .zero, label: $1.1)
        }
        Snapshot.render(desktop(wallpaper) { HintOverlay(model: hintModel) }, size: screen, to: "\(outputDirectory)/hints.png")

        // 키보드 스크롤
        let scrollModel = ScrollModel()
        scrollModel.areas = [MockDocument.contentArea, MockDocument.sidebarArea]
            .map { $0.offsetBy(dx: documentFrame.minX, dy: documentFrame.minY) }
        Snapshot.render(desktop(wallpaper) { ScrollOverlay(model: scrollModel) }, size: screen, to: "\(outputDirectory)/scroll.png")
    }

    /// 바탕화면 + 목업 문서 윈도우 + 오버레이
    private static func desktop(_ wallpaper: CGImage?, @ViewBuilder overlay: () -> some View) -> some View {
        ZStack(alignment: .topLeading) {
            if let wallpaper { Image(decorative: wallpaper, scale: 1).resizable() }
            MockDocument()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                .position(x: documentFrame.midX, y: documentFrame.midY)
            overlay()
        }
        .frame(width: screen.width, height: screen.height)
    }
}

// MARK: - 목업 화면

private extension View {
    /// 왼쪽 위 원점 기준의 영역에 배치한다.
    func place(_ rect: CGRect, alignment: Alignment = .leading) -> some View {
        frame(width: rect.width, height: rect.height, alignment: alignment).position(x: rect.midX, y: rect.midY)
    }
}

struct MockWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.42), Color(red: 0.36, green: 0.22, blue: 0.62),
                                    Color(red: 0.92, green: 0.48, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.25, green: 0.55, blue: 0.95).opacity(0.75), .clear],
                           center: UnitPoint(x: 0.22, y: 0.2), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.40).opacity(0.6), .clear],
                           center: UnitPoint(x: 0.85, y: 0.85), startRadius: 0, endRadius: 640)
        }
    }
}

/// 사이드바 + 본문이 있는 문서 윈도우. 클릭 힌트·스크롤 예시의 대상이기도 하다.
struct MockDocument: View {
    static let size = CGSize(width: 1180, height: 760)
    static let barHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 230
    static let sidebarArea = CGRect(x: 0, y: barHeight, width: sidebarWidth, height: size.height - barHeight)
    static let contentArea = CGRect(x: sidebarWidth, y: barHeight, width: size.width - sidebarWidth, height: size.height - barHeight)

    static let sidebarItems: [(String, String)] = [
        ("sparkles", "Getting Started"), ("keyboard", "Shortcuts"), ("rectangle.3.group", "Window Switcher"),
        ("cursorarrow.rays", "Click Hints"), ("arrow.up.arrow.down", "Keyboard Scroll"),
        ("lock.shield", "Permissions"), ("questionmark.circle", "FAQ"),
    ]
    static let selectedRow = 3
    static func sidebarRow(_ index: Int) -> CGRect {
        CGRect(x: 12, y: barHeight + 16 + CGFloat(index) * 38, width: sidebarWidth - 24, height: 32)
    }

    static let trafficLights = (0..<3).map { CGRect(x: 18 + CGFloat($0) * 22, y: 19, width: 14, height: 14) }
    /// 실제 툴바 버튼처럼 아이콘 왼쪽에 여백이 있는 영역 (힌트 배지는 영역 왼쪽에 붙는다)
    static let toolbar: [(String, CGRect)] = [
        ("sidebar.left", CGRect(x: 92, y: 12, width: 56, height: 28)),
        ("chevron.left", CGRect(x: 244, y: 12, width: 50, height: 28)),
        ("chevron.right", CGRect(x: 298, y: 12, width: 50, height: 28)),
        ("square.and.arrow.up", CGRect(x: 836, y: 12, width: 56, height: 28)),
        ("plus", CGRect(x: 898, y: 12, width: 56, height: 28)),
    ]
    static let searchField = CGRect(x: 968, y: 12, width: 196, height: 28)

    static let contentX = sidebarWidth + 56
    static let primaryButton = CGRect(x: contentX, y: 250, width: 132, height: 36)
    static let secondaryButton = CGRect(x: contentX + 146, y: 250, width: 116, height: 36)
    static let links: [(String, CGRect)] = [
        ("Change shortcuts", CGRect(x: contentX, y: 398, width: 140, height: 22)),
        ("Open permissions", CGRect(x: contentX + 172, y: 398, width: 140, height: 22)),
        ("Troubleshooting", CGRect(x: contentX + 344, y: 398, width: 130, height: 22)),
    ]
    static let cards: [(String, String, CGRect)] = (0..<3).map { index in
        let titles = ["Window Switcher", "Click Hints", "Keyboard Scroll"]
        let keys = ["⌥ Tab", "⌥ F", "⌥ J"]
        return (titles[index], keys[index], CGRect(x: contentX + CGFloat(index) * 280, y: 500, width: 260, height: 170))
    }
    static func cardLink(_ card: CGRect) -> CGRect { CGRect(x: card.minX + 20, y: card.maxY - 44, width: 88, height: 22) }

    /// 손쉬운 사용으로 찾았을 법한 클릭 대상
    static var clickable: [CGRect] {
        trafficLights + toolbar.map(\.1) + [searchField]
            + sidebarItems.indices.map(sidebarRow)
            + [primaryButton, secondaryButton] + links.map(\.1) + cards.map { cardLink($0.2) }
    }

    private let ink = Color(white: 0.13)
    private let faint = Color(white: 0.55)
    private let link = Color(red: 0.05, green: 0.42, blue: 0.95)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Color(white: 0.955).place(CGRect(x: 0, y: 0, width: Self.sidebarWidth, height: Self.size.height))
            Color(white: 0.86).place(CGRect(x: Self.sidebarWidth, y: 0, width: 1, height: Self.size.height))
            Color(white: 0.9).place(CGRect(x: Self.sidebarWidth, y: Self.barHeight, width: Self.size.width - Self.sidebarWidth, height: 1))

            ForEach(0..<3, id: \.self) { index in
                Circle().fill([Color.red, Color.yellow, Color.green][index].opacity(0.9)).place(Self.trafficLights[index])
            }
            ForEach(Self.toolbar, id: \.0) { symbol, rect in
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Color(white: 0.35))
                    .padding(.trailing, 8)
                    .place(rect, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search")
                Spacer()
            }
            .font(.system(size: 13)).foregroundStyle(faint).padding(.horizontal, 9)
            .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .place(Self.searchField)
            Text("Unmouse User Guide").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                .place(CGRect(x: 366, y: 12, width: 400, height: 28))

            ForEach(Array(Self.sidebarItems.enumerated()), id: \.offset) { index, item in
                let selected = index == Self.selectedRow
                HStack(spacing: 9) {
                    Image(systemName: item.0).frame(width: 20)
                    Text(item.1)
                    Spacer()
                }
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : ink)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background(selected ? link : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .place(Self.sidebarRow(index))
            }

            Text("Click Hints").font(.system(size: 34, weight: .bold)).foregroundStyle(ink)
                .place(CGRect(x: Self.contentX, y: 92, width: 600, height: 44))
            Text("Every button, link, and text field gets a letter. Type it to click.")
                .font(.system(size: 17)).foregroundStyle(Color(white: 0.35))
                .place(CGRect(x: Self.contentX, y: 146, width: 800, height: 26))
            Text("Keep your hands on the keyboard. Add ⇧ to right-click, or ⌘ to ⌘-click.")
                .font(.system(size: 15)).foregroundStyle(faint)
                .place(CGRect(x: Self.contentX, y: 184, width: 800, height: 24))

            Text("Try it now").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(link, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .place(Self.primaryButton)
            Text("View source").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .place(Self.secondaryButton)

            Text("Learn more").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink)
                .place(CGRect(x: Self.contentX, y: 332, width: 400, height: 28))
            Text("Shortcuts can be changed in Settings, and the first launch walks you through the permissions.")
                .font(.system(size: 15)).foregroundStyle(Color(white: 0.4))
                .place(CGRect(x: Self.contentX, y: 366, width: 800, height: 22))
            ForEach(Self.links, id: \.0) { title, rect in
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(link).place(rect)
            }

            Text("Three modes").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink)
                .place(CGRect(x: Self.contentX, y: 458, width: 400, height: 28))
            ForEach(Self.cards, id: \.0) { title, key, rect in
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.965)).place(rect)
                Text(key).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color(white: 0.3))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .place(CGRect(x: rect.minX + 20, y: rect.minY + 20, width: 200, height: 26))
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                    .place(CGRect(x: rect.minX + 20, y: rect.minY + 60, width: 220, height: 24))
                Text("Details ›").font(.system(size: 14, weight: .medium)).foregroundStyle(link)
                    .place(Self.cardLink(rect))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .light)
    }
}

struct MockTerminal: View {
    private let lines: [(String, Color)] = [
        ("~/dev/unmouse  main", Color(red: 0.45, green: 0.75, blue: 1.0)),
        ("$ scripts/build-app.sh --install --run", .white),
        ("Building for production...", Color(white: 0.7)),
        ("[5/5] Linking Unmouse", Color(white: 0.7)),
        ("Build complete! (13.58s)", Color(red: 0.45, green: 0.9, blue: 0.55)),
        ("Built build/Unmouse.app", Color(white: 0.7)),
        ("Installed to /Applications/Unmouse.app", Color(white: 0.7)),
        ("", .white),
        ("~/dev/unmouse  main", Color(red: 0.45, green: 0.75, blue: 1.0)),
        ("$ ▍", .white),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { Circle().fill([Color.red, Color.yellow, Color.green][$0].opacity(0.9)).frame(width: 13, height: 13) }
                Spacer()
                Text("unmouse — zsh").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(white: 0.7))
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 40).background(Color(white: 0.16))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.0.isEmpty ? " " : line.0).font(.system(size: 16, design: .monospaced)).foregroundStyle(line.1)
                }
            }
            .padding(20)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
    }
}

struct MockNotes: View {
    private let items = ["Assign hint letters from the home row", "Tab switches the scroll area", "Keyboard-only settings window", "Add screenshots to the README"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { Circle().fill([Color.red, Color.yellow, Color.green][$0].opacity(0.9)).frame(width: 13, height: 13) }
                Spacer()
                Image(systemName: "square.and.pencil").foregroundStyle(Color(red: 0.85, green: 0.6, blue: 0.1))
            }
            .padding(.horizontal, 16).frame(height: 40)
            VStack(alignment: .leading, spacing: 14) {
                Text("Meeting Notes").font(.system(size: 28, weight: .bold))
                Text("This week").font(.system(size: 16)).foregroundStyle(Color(white: 0.45))
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 10) {
                        Image(systemName: index < 2 ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(index < 2 ? Color(red: 0.95, green: 0.7, blue: 0.1) : Color(white: 0.6))
                        Text(item).foregroundStyle(index < 2 ? Color(white: 0.5) : Color(white: 0.15))
                    }
                    .font(.system(size: 17))
                }
            }
            .padding(.horizontal, 28).padding(.top, 8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(white: 0.13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 1.0, green: 0.985, blue: 0.93))
    }
}

struct MockCalendar: View {
    private let events: [Int: (String, Color)] = [
        4: ("Design review", .blue), 9: ("Deploy", .green), 12: ("Lunch", .orange),
        17: ("Retro", .purple), 23: ("Release notes", .blue), 26: ("Vacation", .pink),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { Circle().fill([Color.red, Color.yellow, Color.green][$0].opacity(0.9)).frame(width: 13, height: 13) }
                Text("November").font(.system(size: 24, weight: .bold)).padding(.leading, 16)
                Spacer()
                Text("Today").font(.system(size: 14, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color(white: 0.92), in: Capsule())
            }
            .padding(.horizontal, 16).frame(height: 56)
            HStack(spacing: 0) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) {
                    Text($0).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(white: 0.5)).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 26)
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            let day = row * 7 + column + 1
                            VStack(alignment: .leading, spacing: 4) {
                                Text(day <= 30 ? "\(day)" : "").font(.system(size: 14, weight: day == 15 ? .bold : .regular))
                                    .foregroundStyle(day == 15 ? Color.red : Color(white: 0.2))
                                if let event = events[day] {
                                    Text(event.0).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(event.1.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .border(Color(white: 0.9), width: 0.5)
                        }
                    }
                }
            }
        }
        .foregroundStyle(Color(white: 0.13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}

struct MockFinder: View {
    private let folders = ["Design", "Documents", "Screenshots", "Projects", "References", "Archive", "Drafts", "Releases"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { Circle().fill([Color.red, Color.yellow, Color.green][$0].opacity(0.9)).frame(width: 13, height: 13) }
                Text("Documents").font(.system(size: 15, weight: .semibold)).padding(.leading, 16)
                Spacer()
                Image(systemName: "square.grid.2x2").foregroundStyle(Color(white: 0.4))
            }
            .padding(.horizontal, 16).frame(height: 48).background(Color(white: 0.955))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 34) {
                ForEach(folders, id: \.self) { name in
                    VStack(spacing: 8) {
                        Image(systemName: "folder.fill").font(.system(size: 62)).foregroundStyle(Color(red: 0.3, green: 0.66, blue: 0.98))
                        Text(name).font(.system(size: 14))
                    }
                }
            }
            .padding(40)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(white: 0.13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}
