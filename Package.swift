// swift-tools-version: 6.0
import Foundation
import PackageDescription

// AmendCoreTests uses Swift 5 mode because mock URL protocols and async test harness fixtures
// capture mutable test recording state across concurrent boundaries. AmendCore, AmendApp,
// and Amend production targets strictly compile in Swift 6 language mode (.swiftLanguageMode(.v6)).
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
    name: "Amend",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "AmendCore", targets: ["AmendCore"]),
        .library(name: "AmendApp", targets: ["AmendApp"]),
        .executable(name: "Amend", targets: ["Amend"])
    ],
    dependencies: [
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", from: "14.5.0"),
        .package(url: "https://github.com/orchetect/swift-timecode.git", from: "3.1.4"),
        .package(path: "Packages/FluidAudio")
    ],
    targets: [
        .target(
            name: "AmendCore",
            dependencies: [
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
                .product(name: "SwiftTimecodeCore", package: "swift-timecode"),
                .product(name: "SwiftTimecodeAV", package: "swift-timecode"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AmendApp",
            dependencies: [
                "AmendCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Amend",
            dependencies: [
                "AmendCore",
                "AmendApp"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AmendCoreTests",
            dependencies: [
                "AmendCore",
                "AmendApp",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .copy("Fixtures/human_speech_reference.wav"),
                .copy("Fixtures/README.md")
            ],
            swiftSettings: testSwiftSettings
        )
    ],
    swiftLanguageModes: [.v6]
)
