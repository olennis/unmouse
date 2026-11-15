// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unmouse",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Unmouse",
            path: "Sources/Unmouse",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // SkyLight: 다른 Space의 특정 윈도우를 앞으로 가져오는 데 필요한 비공개 프레임워크
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
