// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cleaner",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Cleaner",
            path: "Sources/Cleaner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
