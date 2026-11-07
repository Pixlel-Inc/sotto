// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SottoCore", targets: ["SottoCore"]),
        .executable(name: "sotto", targets: ["sotto"]),
        .executable(name: "SottoApp", targets: ["SottoApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.2", traits: ["Diarizer"]),
    ],
    targets: [
        .target(
            name: "SottoCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "sotto", dependencies: ["SottoCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "SottoApp",
            dependencies: ["SottoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "SottoCoreTests", dependencies: ["SottoCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
