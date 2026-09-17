// swift-tools-version: 6.0
import Foundation
import PackageDescription

var testSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5)
]

let cltTestingMacrosPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if FileManager.default.fileExists(atPath: cltTestingMacrosPath) {
    testSwiftSettings.append(
        .unsafeFlags([
            "-load-plugin-library",
            cltTestingMacrosPath
        ])
    )
}

let package = Package(
    name: "macdub",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacDubCore", targets: ["MacDubCore"]),
        .library(name: "MacDubApp", targets: ["MacDubApp"]),
        .executable(name: "macdub", targets: ["macdub"])
    ],
    dependencies: [
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", from: "14.5.0"),
        .package(url: "https://github.com/orchetect/swift-timecode.git", from: "3.1.4"),
        .package(path: "Packages/FluidAudio")
    ],
    targets: [
        .target(
            name: "MacDubCore",
            dependencies: [
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
                .product(name: "SwiftTimecodeCore", package: "swift-timecode"),
                .product(name: "SwiftTimecodeAV", package: "swift-timecode"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "MacDubApp",
            dependencies: [
                "MacDubCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "macdub",
            dependencies: [
                "MacDubCore",
                "MacDubApp"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MacDubCoreTests",
            dependencies: [
                "MacDubCore",
                "MacDubApp",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .copy("Fixtures/human_speech_reference.wav"),
                .copy("Fixtures/README.md")
            ],
            swiftSettings: testSwiftSettings
        )
    ],
    swiftLanguageModes: [.v5]
)
