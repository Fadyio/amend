import Foundation
import CoreMedia
import MacDubCore

print("=== MACDUB CROSS-APFS CONTAINER STRESS TEST ===")

let mountPoint = URL(fileURLWithPath: "/Volumes/MacDubTestAPFS")
let apfsTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MacDubAPFSSource2_\(UUID().uuidString)")
try FileManager.default.createDirectory(at: apfsTempDir, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: apfsTempDir)
}

// 1. Verify APFS image volume supports cloning internally
let apfsSupportsCloning = APFSCloner.volumeSupportsCloning(at: mountPoint)
print("APFS image volume supports cloning: \(apfsSupportsCloning)")
assert(apfsSupportsCloning, "APFS image volume must support cloning internally")

// 2. Create source media on main disk
let apfsSourceURL = apfsTempDir.appendingPathComponent("recording.mp4")
let testPayload = Data(repeating: 0x99, count: 128 * 1024)
try testPayload.write(to: apfsSourceURL)

// 3. Test areOnSameVolume between main disk and APFS image
let sameVolume = APFSCloner.areOnSameVolume(apfsSourceURL, mountPoint)
print("Are main disk and mounted APFS image on same volume: \(sameVolume)")
assert(!sameVolume, "Mounted APFS disk image is a separate volume/container!")

// 4. Test canClone between separate APFS volumes
let canCloneCrossAPFS = APFSCloner.canClone(from: apfsSourceURL, to: mountPoint)
print("canClone cross-APFS: \(canCloneCrossAPFS)")
assert(!canCloneCrossAPFS, "canClone must be false across separate APFS volumes/containers!")

// 5. Create ProjectBundle across APFS volumes
let destBundle = mountPoint.appendingPathComponent("CrossAPFSProject")
let bundle = try ProjectBundleSerializer.createBundle(
    at: destBundle,
    sourceMediaURL: apfsSourceURL,
    name: "CrossAPFSProject",
    designatedNarrationTrackID: 1,
    totalDuration: CMTime(value: 3000, timescale: 600)
)

print("Created bundle mode: \(bundle.metadata.sourceStorageMode)")
guard case .externalBookmark = bundle.metadata.sourceStorageMode else {
    fatalError("FAIL: Expected .externalBookmark for cross-APFS-container clone attempt!")
}

let clonedCandidate = bundle.rootURL.appendingPathComponent("source.mp4")
assert(!FileManager.default.fileExists(atPath: clonedCandidate.path), "Must not copy file to separate APFS container!")

let resolved = try ProjectBundleSerializer.resolveSourceMediaURL(for: bundle)
assert(resolved.resolvingSymlinksInPath().path == apfsSourceURL.resolvingSymlinksInPath().path)

print("=== ALL CROSS-APFS TESTS PASSED! ===")
