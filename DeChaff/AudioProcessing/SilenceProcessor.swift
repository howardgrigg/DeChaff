import AVFoundation
import Accelerate

extension VoiceIsolationProcessor {

    // MARK: - Silence detection and shortening

    func detectSilences(inputPath: String, maxKept: Double) -> [SilenceSegment]? {
        let minSilenceDuration = 0.5
        let thresholdLinear: Float = Float(pow(10.0, -40.0 / 20.0))  // -40 dBFS ≈ 0.01
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
            let sr   = file.processingFormat.sampleRate
            let nch  = Int(file.processingFormat.channelCount)
            let chunkSize: AVAudioFrameCount = 4096
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                              frameCapacity: chunkSize) else { return nil }
            let fileLength = AVAudioFrameCount(file.length)
            var readFrames: AVAudioFrameCount = 0
            file.framePosition = 0

            var silenceStart: Double? = nil
            var spans: [(start: Double, end: Double)] = []

            while readFrames < fileLength {
                let toRead = min(chunkSize, fileLength - readFrames)
                buf.frameLength = toRead
                try file.read(into: buf, frameCount: toRead)
                guard buf.frameLength > 0 else { break }

                var sumMS: Float = 0
                for ch in 0..<nch {
                    guard let data = buf.floatChannelData?[ch] else { continue }
                    var ms: Float = 0
                    vDSP_measqv(data, 1, &ms, vDSP_Length(buf.frameLength))
                    sumMS += ms
                }
                let rms = sqrtf(sumMS / Float(nch))
                let chunkStartSec = Double(readFrames) / sr

                if rms < thresholdLinear {
                    if silenceStart == nil { silenceStart = chunkStartSec }
                } else {
                    if let start = silenceStart {
                        spans.append((start: start, end: chunkStartSec))
                        silenceStart = nil
                    }
                }
                readFrames += buf.frameLength
            }
            if let start = silenceStart {
                spans.append((start: start, end: Double(fileLength) / sr))
            }

            return spans.compactMap { span in
                let duration = span.end - span.start
                guard duration >= minSilenceDuration else { return nil }
                return SilenceSegment(startSeconds: span.start, endSeconds: span.end,
                                      keptSeconds: min(duration, maxKept))
            }
        } catch {
            logHandler("❌ Silence detection failed: \(error.localizedDescription)")
            return nil
        }
    }

    func shortenSilenceFrames(inputPath: String, outputPath: String,
                              segments: [SilenceSegment],
                              progressStart: Double, progressEnd: Double) -> Bool {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
            let fmt  = file.processingFormat
            let sr   = fmt.sampleRate
            var silenceOutSettings = fmt.settings
            silenceOutSettings.removeValue(forKey: AVChannelLayoutKey)
            let outFile = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath),
                                          settings: silenceOutSettings)
            let chunkSize: AVAudioFrameCount = 4096
            guard let buf     = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkSize),
                  let scratch = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkSize) else { return false }

            // Pre-compute the frame ranges to skip (leading portion of each qualifying silent span)
            let removedRanges: [(start: Int64, end: Int64)] = segments.compactMap { seg in
                let removedSecs = (seg.endSeconds - seg.startSeconds) - seg.keptSeconds
                guard removedSecs > 0 else { return nil }
                return (Int64(seg.startSeconds * sr), Int64((seg.startSeconds + removedSecs) * sr))
            }

            let fileLength = Int64(file.length)
            var inputPos: Int64 = 0
            var processed: Int64 = 0
            var regionIdx = 0
            file.framePosition = 0

            while inputPos < fileLength {
                let toRead = min(Int64(chunkSize), fileLength - inputPos)
                buf.frameLength = AVAudioFrameCount(toRead)
                try file.read(into: buf, frameCount: buf.frameLength)
                guard buf.frameLength > 0 else { break }

                let chunkStart = inputPos
                let chunkEnd   = inputPos + Int64(buf.frameLength)

                // Advance cursor past regions that end before this chunk
                while regionIdx < removedRanges.count && removedRanges[regionIdx].end <= chunkStart {
                    regionIdx += 1
                }

                if regionIdx >= removedRanges.count || removedRanges[regionIdx].start >= chunkEnd {
                    // No removed region overlaps this chunk — write verbatim
                    try outFile.write(from: buf)
                } else {
                    // Chunk straddles a removed region boundary — write sub-ranges only
                    var writeStart = chunkStart
                    var ri = regionIdx
                    while writeStart < chunkEnd {
                        let rStart = ri < removedRanges.count ? removedRanges[ri].start : chunkEnd
                        let rEnd   = ri < removedRanges.count ? removedRanges[ri].end   : chunkEnd
                        if rStart >= chunkEnd {
                            // Next removed region starts after this chunk — write remaining frames
                            let off = Int(writeStart - chunkStart)
                            let cnt = Int(chunkEnd - writeStart)
                            if cnt > 0 { try writeSubrange(from: buf, into: scratch,
                                                            offset: off, count: cnt, to: outFile) }
                            break
                        } else if rEnd <= writeStart {
                            ri += 1  // this region ends before writeStart — skip it
                        } else {
                            // Region overlaps [writeStart, chunkEnd)
                            let beforeEnd = min(rStart, chunkEnd)
                            if beforeEnd > writeStart {
                                let off = Int(writeStart - chunkStart)
                                let cnt = Int(beforeEnd - writeStart)
                                try writeSubrange(from: buf, into: scratch,
                                                  offset: off, count: cnt, to: outFile)
                            }
                            writeStart = min(rEnd, chunkEnd)
                            if writeStart < rEnd { break }  // removed region extends past chunk
                            ri += 1
                        }
                    }
                }

                inputPos = chunkEnd
                processed += Int64(buf.frameLength)
                progressHandler(progressStart + (progressEnd - progressStart) * Double(processed) / Double(fileLength))
            }

            let totalRemoved = segments.reduce(0.0) {
                $0 + max(0, ($1.endSeconds - $1.startSeconds) - $1.keptSeconds)
            }
            let segCount = segments.filter { ($0.endSeconds - $0.startSeconds - $0.keptSeconds) > 0 }.count
            logHandler(String(format: "✂️ Shortened silences: removed %.1fs across %d segment%@",
                              totalRemoved, segCount, segCount == 1 ? "" : "s"))
            return true
        } catch {
            logHandler("❌ Silence shortening failed: \(error.localizedDescription)")
            return false
        }
    }

    private func writeSubrange(from src: AVAudioPCMBuffer, into scratch: AVAudioPCMBuffer,
                                offset: Int, count: Int, to file: AVAudioFile) throws {
        scratch.frameLength = AVAudioFrameCount(count)
        for ch in 0..<Int(src.format.channelCount) {
            guard let s = src.floatChannelData?[ch],
                  let d = scratch.floatChannelData?[ch] else { continue }
            memcpy(d, s.advanced(by: offset), count * MemoryLayout<Float>.size)
        }
        try file.write(from: scratch)
    }
}

/// Remaps a chapter timestamp from the original audio timeline to the shortened output timeline.
/// Chapters falling inside a removed silent region snap to the end of the kept tail.
func remapChapterTime(_ timeSeconds: Double, using segments: [SilenceSegment]) -> Double {
    var removedBefore = 0.0
    for seg in segments {
        let removedInSeg     = (seg.endSeconds - seg.startSeconds) - seg.keptSeconds
        let removedRegionEnd = seg.startSeconds + removedInSeg
        if timeSeconds <= seg.startSeconds { break }
        else if timeSeconds < removedRegionEnd {
            removedBefore += (timeSeconds - seg.startSeconds); break
        } else {
            removedBefore += removedInSeg
        }
    }
    return max(0, timeSeconds - removedBefore)
}
