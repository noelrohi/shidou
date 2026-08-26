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
        .executable(name: "shidou-probe", targets: ["shidou-probe"]),
    ],
    targets: [
        .target(name: "ShidouProtocol"),
        .target(name: "ShidouClient", dependencies: ["ShidouProtocol"]),
        .target(name: "ShidouSession", dependencies: ["ShidouProtocol", "ShidouClient"]),
        .executableTarget(name: "shidou-probe", dependencies: ["ShidouProtocol", "ShidouClient"]),
        .testTarget(
            name: "ShidouProtocolTests",
            dependencies: ["ShidouProtocol"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ShidouClientTests", dependencies: ["ShidouClient"]),
        .testTarget(name: "ShidouSessionTests", dependencies: ["ShidouSession"]),
    ]
)
