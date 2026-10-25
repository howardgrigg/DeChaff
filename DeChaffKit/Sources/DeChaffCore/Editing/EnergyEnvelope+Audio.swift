import AVFoundation
import Accelerate

extension EnergyEnvelope {
    /// Reads `range` (seconds) of an audio file into an envelope. Channels are combined
    /// by averaging their mean-square level, the same way silence detection measures RMS.
    public init(contentsOf url: URL, range: ClosedRange<Double>, frameDuration: Double = 0.01) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let nch = Int(format.channelCount)
        let startFrame = min(max(0, AVAudioFramePosition(range.lowerBound * sr)), file.length)
        let endFrame   = min(max(startFrame, AVAudioFramePosition(range.upperBound * sr)), file.length)
        let frameLength = max(1, Int(sr * frameDuration))

        // Read whole envelope frames per chunk so only the final frame can be partial.
        let chunkFrames = AVAudioFrameCount(frameLength * 512)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileReadUnknown)
        }
        var levels: [Float] = []
        levels.reserveCapacity(Int(endFrame - startFrame) / frameLength + 1)
        var remaining = Int(endFrame - startFrame)
        file.framePosition = startFrame

        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(Int(chunkFrames), remaining))
            buf.frameLength = toRead
            try file.read(into: buf, frameCount: toRead)
            let n = Int(buf.frameLength)
            guard n > 0 else { break }
            var offset = 0
            while offset < n {
                let len = min(frameLength, n - offset)
                var sum: Float = 0
                for ch in 0..<nch {
                    guard let data = buf.floatChannelData?[ch] else { continue }
                    var ms: Float = 0
                    vDSP_measqv(data.advanced(by: offset), 1, &ms, vDSP_Length(len))
                    sum += ms
                }
                levels.append(EnergyEnvelope.decibels(meanSquare: sum / Float(max(nch, 1))))
                offset += len
            }
            remaining -= n
        }

        self.init(startTime: Double(startFrame) / sr,
                  frameDuration: Double(frameLength) / sr,
                  levelsDB: levels)
    }
}

extension CutPointRefiner {
    /// Refines a cut against an audio file, reading only the audio around `time`.
    /// With an empty `words` list the cut is refined from the audio alone.
    public func refine(edge: CutEdge, time: Double, words: [TranscriptWord],
                       audioURL: URL) throws -> CutRefinement {
        let envelope = try EnergyEnvelope(contentsOf: audioURL, range: analysisWindow(around: time))
        return refine(edge: edge, time: time, words: words, envelope: envelope)
    }

    /// Refines a cut just before (`.start`) or after (`.end`) `words[wordIndex]`.
    public func refine(edge: CutEdge, wordIndex: Int, words: [TranscriptWord],
                       audioURL: URL) throws -> CutRefinement {
        let anchor = edge == .start ? words[wordIndex].startTime : words[wordIndex].endTime
        let envelope = try EnergyEnvelope(contentsOf: audioURL, range: analysisWindow(around: anchor))
        return refine(edge: edge, wordIndex: wordIndex, words: words, envelope: envelope)
    }
}
