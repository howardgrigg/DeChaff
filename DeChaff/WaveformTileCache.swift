import Foundation
import CoreGraphics
import AVFoundation
import Accelerate

// MARK: - Multi-resolution peak data

struct WaveformData {
    /// Level 0: ~1000 frames/peak (~44 peaks/sec at 44.1kHz) — high zoom
    let level0: [Float]
    /// Level 1: ~10,000 frames/peak (~4.4 peaks/sec) — medium zoom
    let level1: [Float]
    /// Level 2: ~100,000 frames/peak (~0.44 peaks/sec) — overview
    let level2: [Float]
    let duration: Double
    let sampleRate: Double

    static let framesPerPeak: [Int] = [1000, 10_000, 100_000]

    /// Pick the best resolution level for a given zoom so peaks-per-pixel >= 1.
    func peaks(forZoom zoom: Double, viewportWidth: CGFloat) -> (peaks: [Float], framesPerPeak: Int) {
        let visibleDuration = duration / zoom
        let secondsPerPixel = visibleDuration / Double(max(1, viewportWidth))
        // We want at least 1 peak per pixel. Pick finest level where that holds.
        for (i, fpp) in Self.framesPerPeak.enumerated() {
            let peaksPerSecond = sampleRate / Double(fpp)
            let peaksPerPixel = peaksPerSecond * secondsPerPixel
            if peaksPerPixel >= 1.0 {
                switch i {
                case 0: return (level0, fpp)
                case 1: return (level1, fpp)
                default: return (level2, fpp)
                }
            }
        }
        return (level0, Self.framesPerPeak[0])
    }
}

/// Generate multi-resolution peaks in a single streaming pass.
func generateMultiResWaveform(url: URL) async -> (data: WaveformData?, duration: Double) {
    guard let file = try? AVAudioFile(forReading: url) else { return (nil, 0) }
    let sr = file.processingFormat.sampleRate
    let totalFrames = file.length
    let duration = Double(totalFrames) / sr
    let nch = Int(file.processingFormat.channelCount)

    let fpp = WaveformData.framesPerPeak  // [1000, 10_000, 100_000]
    let expectedCounts = fpp.map { max(1, Int(totalFrames) / $0 + 1) }

    var peaks: [[Float]] = [
        { var a = [Float](); a.reserveCapacity(expectedCounts[0]); return a }(),
        { var a = [Float](); a.reserveCapacity(expectedCounts[1]); return a }(),
        { var a = [Float](); a.reserveCapacity(expectedCounts[2]); return a }(),
    ]

    // Accumulators for each level
    var accMax: [Float] = [0, 0, 0]
    var accCount: [Int] = [0, 0, 0]

    let chunkSize: AVAudioFrameCount = 16384
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else {
        return (nil, duration)
    }

    file.framePosition = 0
    while file.framePosition < totalFrames {
        buf.frameLength = min(chunkSize, AVAudioFrameCount(totalFrames - file.framePosition))
        guard (try? file.read(into: buf, frameCount: buf.frameLength)) != nil, buf.frameLength > 0 else { break }

        // Process frame-by-frame within this chunk using sub-buckets of fpp[0] frames
        let frameCount = Int(buf.frameLength)
        var offset = 0
        while offset < frameCount {
            // For level 0, figure out how many frames until next bucket boundary
            let remaining0 = fpp[0] - accCount[0]
            let take = min(remaining0, frameCount - offset)

            // Find peak in this sub-range across all channels
            var subPeak: Float = 0
            for ch in 0..<nch {
                guard let data = buf.floatChannelData?[ch] else { continue }
                var chPeak: Float = 0
                vDSP_maxmgv(data.advanced(by: offset), 1, &chPeak, vDSP_Length(take))
                subPeak = max(subPeak, chPeak)
            }

            // Accumulate into all levels
            for lvl in 0..<3 {
                accMax[lvl] = max(accMax[lvl], subPeak)
                accCount[lvl] += take
                if accCount[lvl] >= fpp[lvl] {
                    peaks[lvl].append(accMax[lvl])
                    accMax[lvl] = 0
                    accCount[lvl] = 0
                }
            }

            offset += take
        }
    }

    // Flush any remaining partial buckets
    for lvl in 0..<3 {
        if accCount[lvl] > 0 {
            peaks[lvl].append(accMax[lvl])
        }
    }

    // Normalize each level to 0..1
    for lvl in 0..<3 {
        var maxVal: Float = 0
        vDSP_maxv(peaks[lvl], 1, &maxVal, vDSP_Length(peaks[lvl].count))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(peaks[lvl], 1, &scale, &peaks[lvl], 1, vDSP_Length(peaks[lvl].count))
        }
    }

    let data = WaveformData(
        level0: peaks[0], level1: peaks[1], level2: peaks[2],
        duration: duration, sampleRate: sr
    )
    return (data, duration)
}

// MARK: - Tile cache

final class WaveformTileCache: @unchecked Sendable {
    struct TileKey: Hashable {
        let zoomLevel: Int  // quantised zoom
        let tileIndex: Int
        let trimInHash: Int
        let trimOutHash: Int
    }

    let tileWidth: CGFloat = 512

    private var cache: [TileKey: CGImage] = [:]
    private var accessOrder: [TileKey] = []
    private let maxTiles = 64
    private let queue = DispatchQueue(label: "WaveformTileCache", qos: .userInitiated)

    func invalidateAll() {
        queue.sync {
            cache.removeAll()
            accessOrder.removeAll()
        }
    }

    func tile(for key: TileKey) -> CGImage? {
        queue.sync { cache[key] }
    }

    func renderTile(
        key: TileKey,
        peaks: [Float],
        framesPerPeak: Int,
        sampleRate: Double,
        duration: Double,
        tileOriginSeconds: Double,
        tileDurationSeconds: Double,
        trimIn: Double,
        trimOut: Double,
        height: CGFloat,
        accentColor: CGColor,
        dimColor: CGColor
    ) -> CGImage? {
        // Check cache first
        if let existing = queue.sync(execute: { cache[key] }) {
            return existing
        }

        let w = Int(tileWidth)
        let h = Int(height)
        guard w > 0, h > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // Flip coordinate system (origin top-left)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // Clear
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        let midY = CGFloat(h) / 2

        // Draw bars
        let peaksPerSecond = sampleRate / Double(framesPerPeak)
        let secondsPerPixel = tileDurationSeconds / Double(w)
        let barWidth = max(1.0, 1.0 / (peaksPerSecond * secondsPerPixel))

        for px in 0..<w {
            let t = tileOriginSeconds + Double(px) * secondsPerPixel
            let peakIdx = Int(t * peaksPerSecond)
            guard peakIdx >= 0, peakIdx < peaks.count else { continue }
            let sample = peaks[peakIdx]
            let barH = max(1, CGFloat(sample) * midY * 0.9)
            let inTrim = t >= trimIn && t <= trimOut

            if inTrim {
                ctx.setFillColor(accentColor)
            } else {
                ctx.setFillColor(dimColor)
            }
            ctx.fill(CGRect(x: CGFloat(px), y: midY - barH, width: max(1, barWidth - 0.5), height: barH * 2))
        }

        guard let image = ctx.makeImage() else { return nil }

        queue.sync {
            cache[key] = image
            accessOrder.append(key)
            // Evict oldest if over limit
            while accessOrder.count > maxTiles {
                let evict = accessOrder.removeFirst()
                cache.removeValue(forKey: evict)
            }
        }

        return image
    }

    /// Quantise zoom to reduce cache churn — steps of ~5%
    static func quantiseZoom(_ zoom: Double) -> Int {
        Int(round(log2(zoom) * 20))
    }
}
