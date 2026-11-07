// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ExchangeMail",
    platforms: [.macOS(.v26)],
    dependencies: [
        // 자동 업데이트 (1.0.2). 소개 사이트의 appcast.xml을 보고, EdDSA 서명을 확인한 DMG로 바꾼다.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "ExchangeMailKit"),
        .executableTarget(
            name: "ExchangeMail",
            dependencies: ["ExchangeMailKit", .product(name: "Sparkle", package: "Sparkle")],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ExchangeMailKitTests", dependencies: ["ExchangeMailKit"]),
    ]
)
