// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WhereverInterface",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WhereverInterface", targets: ["WhereverInterface"])],
    targets: [
        .target(
            name: "WhereverInterface",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .treatAllWarnings(as: .error),
            ]
        )
    ]
)
