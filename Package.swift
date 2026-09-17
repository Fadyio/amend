// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macdub",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacDubCore", targets: ["MacDubCore"]),
        .executable(name: "macdub", targets: ["macdub"])
    ],
    dependencies: [
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", from: "14.5.0"),
        .package(url: "https://github.com/orchetect/swift-timecode.git", from: "3.1.4"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1")
    ],
    targets: [
        .target(
            name: "MacDubCore",
            dependencies: [
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
                .product(name: "SwiftTimecodeCore", package: "swift-timecode"),
                .product(name: "SwiftTimecodeAV", package: "swift-timecode"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "FluidAudioTTS", package: "FluidAudio")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "macdub",
            dependencies: [
                "MacDubCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MacDubCoreTests",
            dependencies: ["MacDubCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags([
                    "-load-plugin-library",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
                ])
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
