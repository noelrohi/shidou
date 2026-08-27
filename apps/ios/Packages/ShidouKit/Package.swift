// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ShidouKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ShidouProtocol", targets: ["ShidouProtocol"]),
        .library(name: "ShidouClient", targets: ["ShidouClient"]),
        .library(name: "ShidouSession", targets: ["ShidouSession"]),
        .library(name: "ShidouMarkdown", targets: ["ShidouMarkdown"]),
        .executable(name: "shidou-probe", targets: ["shidou-probe"]),
    ],
    dependencies: [
        // The streaming-transcript decision (#6): swift-markdown parses, and
        // the desktop's stable-prefix and mend algorithms sit on top of it.
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.4.0"),
    ],
    targets: [
        .target(name: "ShidouProtocol"),
        .target(name: "ShidouClient", dependencies: ["ShidouProtocol"]),
        .target(name: "ShidouSession", dependencies: ["ShidouProtocol", "ShidouClient"]),
        .target(
            name: "ShidouMarkdown",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .executableTarget(name: "shidou-probe", dependencies: ["ShidouProtocol", "ShidouClient"]),
        .testTarget(
            name: "ShidouProtocolTests",
            dependencies: ["ShidouProtocol"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ShidouClientTests", dependencies: ["ShidouClient"]),
        .testTarget(name: "ShidouSessionTests", dependencies: ["ShidouSession"]),
        .testTarget(name: "ShidouMarkdownTests", dependencies: ["ShidouMarkdown"]),
    ]
)
