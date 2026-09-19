import Foundation
import CoreMedia
import AmendCore

print("=== AMEND CROSS-VOLUME & BOOKMARK FALLBACK STRESS TEST ===")

let mountPoint = URL(fileURLWithPath: "/Volumes/AmendTestHFS")
let apfsTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AmendAPFSSource_\(UUID().uuidString)")
try FileManager.default.createDirectory(at: apfsTempDir, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: apfsTempDir)
}

// 1. Verify HFS+ does not support cloning
let hfsSupportsCloning = APFSCloner.volumeSupportsCloning(at: mountPoint)
print("HFS+ volume supports cloning: \(hfsSupportsCloning)")
assert(!hfsSupportsCloning, "HFS+ volume must NOT support APFS cloning")

// 2. Create source media on APFS
let apfsSourceURL = apfsTempDir.appendingPathComponent("recording.mp4")
let testPayload = Data(repeating: 0x42, count: 256 * 1024) // 256 KB
try testPayload.write(to: apfsSourceURL)

// 3. Test canClone from APFS to HFS+
let hfsDestBundle = mountPoint.appendingPathComponent("TestCrossProject")
let canCloneToHFS = APFSCloner.canClone(from: apfsSourceURL, to: hfsDestBundle)
print("canClone from APFS to HFS+: \(canCloneToHFS)")
assert(!canCloneToHFS, "canClone from APFS to HFS+ volume must return false")

// 4. Create ProjectBundle across volumes (source on APFS, bundle on HFS+)
let bundle = try ProjectBundleSerializer.createBundle(
    at: hfsDestBundle,
    sourceMediaURL: apfsSourceURL,
    name: "CrossVolumeProject",
    designatedNarrationTrackID: 1,
    passthroughTrackIDs: [2],
    isSingleTrackAdvisory: false,
    totalDuration: CMTime(value: 6000, timescale: 600)
)

print("Created bundle URL: \(bundle.rootURL.path)")
assert(bundle.rootURL.pathExtension == "amend", "Bundle extension must be amend")

// 5. Verify sourceStorageMode is externalBookmark
switch bundle.metadata.sourceStorageMode {
case .cloned:
    fatalError("FAIL: Cross-volume bundle incorrectly chose .cloned mode!")
case .externalBookmark(let bookmarkData, let originalPath):
    print("SUCCESS: Mode is .externalBookmark")
    assert(!bookmarkData.isEmpty, "Bookmark data must not be empty")
    print("Original path recorded: \(originalPath)")
    assert(originalPath == apfsSourceURL.path, "Original path must match source")
}

// 6. Verify NO large media file was copied into the foreign volume bundle
let clonedFileCandidate = bundle.rootURL.appendingPathComponent("source.mp4")
assert(!FileManager.default.fileExists(atPath: clonedFileCandidate.path), "CRITICAL: Foreign volume must NOT perform multi-gigabyte file copy!")

// 7. Verify bookmark resolution back to source
let resolvedURL = try ProjectBundleSerializer.resolveSourceMediaURL(for: bundle)
print("Resolved source URL: \(resolvedURL.path)")
assert(resolvedURL.resolvingSymlinksInPath().path == apfsSourceURL.resolvingSymlinksInPath().path, "Resolved bookmark URL must match original source URL")
let resolvedData = try Data(contentsOf: resolvedURL)
assert(resolvedData == testPayload, "Resolved source file contents must match original payload")

print("=== ALL CROSS-VOLUME & BOOKMARK FALLBACK TESTS PASSED! ===")
