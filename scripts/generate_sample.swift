import Foundation
import CoreMedia
import AmendCore
import AmendApp

@main
struct GenerateSample {
    static func main() async throws {
        let sampleDir = URL(fileURLWithPath: "/tmp/amend_demo")
        try? FileManager.default.removeItem(at: sampleDir)
        try FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)

        let movieURL = sampleDir.appendingPathComponent("HackathonDemo.mov")
        print("Generating synthetic sample video at: \(movieURL.path)")
        _ = try await Fixture1SingleTrack.generate(at: movieURL)

        print("Successfully generated: \(movieURL.path)")
    }
}
