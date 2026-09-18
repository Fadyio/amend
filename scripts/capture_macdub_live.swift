import Cocoa
import Foundation
import CoreGraphics

let appPath = "/Users/fady/Dev/macdub/dist/MacDub.app/Contents/MacOS/MacDub"
let mediaPath = "/tmp/macdub_demo/HackathonDemo.voicefix"
let screenshotPath = "/Users/fady/Dev/macdub/docs/screenshots/5_running_app_reference_monitor.png"

let process = Process()
process.executableURL = URL(fileURLWithPath: appPath)
process.arguments = [mediaPath]

print("Launching MacDub at \(appPath) with \(mediaPath)...")
try process.run()
print("Launched process PID: \(process.processIdentifier)")

var targetWindowID: CGWindowID?
var targetBounds: [String: Any]?

// Poll for window for up to 15 seconds
for attempt in 1...30 {
    Thread.sleep(forTimeInterval: 0.5)
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        continue
    }
    for w in windowList {
        let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
        let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
        let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        
        if pid == process.processIdentifier && width > 400 && height > 300 {
            targetWindowID = id
            targetBounds = bounds
            print("Found MacDub Window (Attempt \(attempt)): ID=\(id), Bounds=\(bounds)")
            break
        }
    }
    if targetWindowID != nil { break }
}

guard let winID = targetWindowID else {
    print("Error: Could not find MacDub window.")
    process.terminate()
    exit(1)
}

// Activate application to ensure it's frontmost and fully rendered
if let runningApp = NSRunningApplication(processIdentifier: process.processIdentifier) {
    runningApp.activate()
}

// Give AVPlayer, CALayer, and AppKit 4 seconds to decode and composite the video frame
print("Waiting 4 seconds for video frame rendering in Reference Monitor...")
Thread.sleep(forTimeInterval: 4.0)

// Capture genuine window screenshot
let captureProcess = Process()
captureProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
captureProcess.arguments = ["-o", "-l\(winID)", screenshotPath]
try captureProcess.run()
captureProcess.waitUntilExit()

print("Screenshot captured to \(screenshotPath)")

// Gracefully terminate app
process.terminate()
print("Terminated MacDub process.")
