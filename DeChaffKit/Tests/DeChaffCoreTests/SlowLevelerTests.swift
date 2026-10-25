import AVFoundation
import Testing
@testable import DeChaffCore

@Suite struct SlowLevelerTests {
    /// AVAudioFile returns short reads (44,032 of 44,100 frames) on float WAVs; the
    /// leveler used to treat each as a full window and lose ~68 frames per second,
    /// which cut the last few seconds off a long episode.
    @Test func keepsEveryFrame() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dechaff-leveler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.wav"), output = dir.appendingPathComponent("out.wav")

        // 2 minutes plus a partial window, alternating quiet and loud passages so
        // the gain map has real work to do.
        let sr = 44_100.0
        let frames = AVAudioFrameCount(sr * 120 + 12_345)
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buf.frameLength = frames
            let d = buf.floatChannelData![0]
            for i in 0..<Int(frames) {
                let level: Float = (i / Int(sr * 10)) % 2 == 0 ? 0.05 : 0.3
                d[i] = level * sin(Float(i) * 2 * .pi * 220 / Float(sr))
            }
            try file.write(from: buf)
        }

        let processor = VoiceIsolationProcessor()
        #expect(processor.applySlowLeveler(inputPath: input.path, outputPath: output.path,
                                           progressStart: 0, progressEnd: 1))
        let inLength = try AVAudioFile(forReading: input).length
        let outLength = try AVAudioFile(forReading: output).length
        #expect(inLength == AVAudioFramePosition(frames))
        #expect(outLength == inLength)
    }
}
