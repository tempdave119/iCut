// swift-tools-version:5.8
// 注意：本机仅有 Command Line Tools，SwiftPM 会因缺少 PlatformPath 而无法运行。
// 当前构建走 scripts/build-app.sh（swiftc + lipo）；本清单保留给将来装完整 Xcode 后的标准入口。
import PackageDescription

let package = Package(
    name: "iCut",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "iCut", targets: ["iCut"])
    ],
    targets: [
        .executableTarget(
            name: "iCut",
            path: "src/iCut"
        )
    ]
)
