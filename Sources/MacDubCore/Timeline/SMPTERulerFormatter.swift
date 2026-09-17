import Foundation
import CoreMedia
import CoreGraphics
@_exported import SwiftTimecodeCore

/// Model representing an individual tick mark along the timeline ruler.
public struct RulerTick: Identifiable, Equatable, Sendable {
    public let id: String
    public let time: CMTime
    public let pixelOffset: CGFloat
    public let isMajor: Bool
    public let label: String?

    public init(id: String, time: CMTime, pixelOffset: CGFloat, isMajor: Bool, label: String?) {
        self.id = id
        self.time = time
        self.pixelOffset = pixelOffset
        self.isMajor = isMajor
        self.label = label
    }
}

public extension TimecodeFrameRate {
    /// Returns the real-time nominal frame rate as a floating-point value.
    var realTimeFPS: Double {
        switch self {
        case .fps23_976: return 24.0 / 1.001
        case .fps24: return 24.0
        case .fps24_98: return 25.0 / 1.001
        case .fps25: return 25.0
        case .fps29_97, .fps29_97d: return 30.0 / 1.001
        case .fps30, .fps30d: return 30.0
        case .fps47_952: return 48.0 / 1.001
        case .fps48: return 48.0
        case .fps50: return 50.0
        case .fps59_94, .fps59_94d: return 60.0 / 1.001
        case .fps60, .fps60d: return 60.0
        case .fps90: return 90.0
        case .fps95_904: return 96.0 / 1.001
        case .fps96: return 96.0
        case .fps100: return 100.0
        case .fps119_88, .fps119_88d: return 120.0 / 1.001
        case .fps120, .fps120d: return 120.0
        }
    }

    /// Finds the closest matching standard TimecodeFrameRate for a given nominal FPS value.
    static func closest(to fps: Double) -> TimecodeFrameRate {
        let candidates: [TimecodeFrameRate] = [
            .fps23_976, .fps24, .fps25, .fps29_97, .fps30,
            .fps50, .fps59_94, .fps60, .fps120
        ]
        return candidates.min(by: { abs($0.realTimeFPS - fps) < abs($1.realTimeFPS - fps) }) ?? .fps30
    }
}

/// Formatter providing frame-rate aware SMPTE timecode conversions and dynamic ruler tick subdivision.
public final class SMPTERulerFormatter: Sendable {
    public let frameRate: TimecodeFrameRate

    public init(frameRate: TimecodeFrameRate = .fps30) {
        self.frameRate = frameRate
    }

    /// Converts a continuous CMTime into a SMPTE timecode string (e.g. "00:01:23:15" or "00:01:23;15").
    public func string(from time: CMTime, includeSubFrames: Bool = false) -> String {
        guard time.isValid && !time.isIndefinite else { return "00:00:00:00" }
        do {
            let tc = try Timecode(.cmTime(time), at: frameRate)
            let format: Timecode.StringFormat = includeSubFrames ? [.showSubFrames] : []
            return tc.stringValue(format: format)
        } catch {
            return "00:00:00:00"
        }
    }

    /// Parses a SMPTE timecode string back into an exact CMTime.
    public func time(from timecodeString: String) throws -> CMTime {
        let tc = try Timecode(.string(timecodeString), at: frameRate)
        return tc.cmTimeValue
    }

    /// Computes the dynamic major tick interval based on zoom scale.
    public func majorInterval(for pixelsPerSecond: Double, targetPixelSpacing: CGFloat = 100.0) -> TimeInterval {
        guard pixelsPerSecond > 0 else { return 1.0 }
        let idealTime = Double(targetPixelSpacing) / pixelsPerSecond
        let fps = frameRate.realTimeFPS
        let frameDuration = 1.0 / fps

        let ladder: [TimeInterval] = [
            3600.0, 1800.0, 600.0, 300.0, 60.0, 30.0, 15.0, 10.0, 5.0, 2.0, 1.0, 0.5,
            frameDuration * 15.0,
            frameDuration * 5.0,
            frameDuration * 2.0,
            frameDuration,
            frameDuration * 0.5
        ]

        for step in ladder.reversed() {
            if step >= idealTime {
                return step
            }
        }
        return ladder.first ?? 1.0
    }

    /// Generates visible ruler ticks culled to the current scroll viewport.
    public func generateTicks(
        visibleRect: CGRect,
        pixelsPerSecond: Double,
        totalDuration: CMTime
    ) -> [RulerTick] {
        guard pixelsPerSecond > 0 else { return [] }
        let totalSec = max(0.0, totalDuration.isValid && !totalDuration.isIndefinite ? CMTimeGetSeconds(totalDuration) : 0.0)
        let interval = majorInterval(for: pixelsPerSecond)
        guard interval > 0 else { return [] }

        let startSec = max(0.0, Double(visibleRect.minX) / pixelsPerSecond)
        let endSec = min(totalSec, Double(visibleRect.maxX) / pixelsPerSecond)
        guard startSec <= endSec else { return [] }

        var ticks: [RulerTick] = []
        let firstIndex = max(0, Int(floor(startSec / interval)))
        let lastIndex = Int(ceil(endSec / interval))

        for i in firstIndex...lastIndex {
            let tickSec = Double(i) * interval
            if tickSec > totalSec + 0.0001 { break }

            let tickTime = CMTime(seconds: tickSec, preferredTimescale: 600_000)
            let pixelOffset = CGFloat(tickSec * pixelsPerSecond)
            let labelText = string(from: tickTime)

            ticks.append(RulerTick(
                id: "major_\(i)",
                time: tickTime,
                pixelOffset: pixelOffset,
                isMajor: true,
                label: labelText
            ))

            // Subdivide into 4 minor ticks between major intervals if spacing allows
            let pixelSpacing = CGFloat(interval * pixelsPerSecond)
            if pixelSpacing >= 40.0 {
                let subStep = interval / 4.0
                for sub in 1..<4 {
                    let subSec = tickSec + Double(sub) * subStep
                    if subSec > totalSec || subSec > endSec { break }
                    let subTime = CMTime(seconds: subSec, preferredTimescale: 600_000)
                    let subPixelOffset = CGFloat(subSec * pixelsPerSecond)
                    ticks.append(RulerTick(
                        id: "minor_\(i)_\(sub)",
                        time: subTime,
                        pixelOffset: subPixelOffset,
                        isMajor: false,
                        label: nil
                    ))
                }
            }
        }

        return ticks
    }
}
