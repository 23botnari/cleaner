// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CuratenieMac",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CuratenieMac",
            path: "Sources/CuratenieMac",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
