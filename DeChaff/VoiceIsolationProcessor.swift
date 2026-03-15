import Foundation
import AudioToolbox
import AVFoundation
import Accelerate

enum OutputFormat: String, CaseIterable {
    case wav = "WAV"
    case mp3 = "MP3"
    var fileExtension: String { rawValue.lowercased() }
}

struct Chapter: Identifiable {
    let id: UUID
    var timeSeconds: Double
    var title: String

    init(id: UUID = UUID(), timeSeconds: Double, title: String) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.title = title
    }
}

struct ID3Metadata {
    var title:   String = ""
    var artist:  String = ""
    var album:   String = ""
    var year:    String = ""
    var artwork: Data?  = nil
}

struct ProcessingOptions {
    var voiceIsolation: Bool = true
    var compression: Bool = true
    var normalization: Bool = true
    var monoOutput: Bool = false
    var targetLUFS: Double = -16.0
    var outputFormat: OutputFormat = .wav
    var mp3Bitrate: Int = 64  // kbps CBR (64 / 96 / 128 / 192 / 256)
    var shortenSilences: Bool = false
    var maxSilenceDuration: Double = 1.0  // seconds to retain at the tail of each silent span
    var trimInSeconds: Double = 0
    var trimOutSeconds: Double = 0  // 0 = use full file duration
}

struct SilenceSegment {
    let startSeconds: Double
    let endSeconds:   Double
    let keptSeconds:  Double  // portion retained at tail of the silent span
}

class VoiceIsolationProcessor {
    private let isolationSubType: UInt32 = 0x766f6973
    private var logHandler: (String) -> Void = { _ in }
    private var progressHandler: (Double) -> Void = { _ in }
    private(set) var detectedSilenceSegments: [SilenceSegment] = []

    func process(
        inputPath: String,
        outputPath: String,
        options: ProcessingOptions,
        progressHandler: @escaping (Double) -> Void,
        logHandler: @escaping (String) -> Void
    ) -> Bool {
        self.progressHandler = progressHandler
        self.logHandler = logHandler

        guard FileManager.default.fileExists(atPath: inputPath) else {
            logHandler("❌ Input file not found"); return false
        }
        guard let audioFile = loadAudioFile(path: inputPath) else { return false }

        let needsAU = options.voiceIsolation || options.compression
        let encodingMP3 = options.outputFormat == .mp3

        // Scale AU+normalization progress; silence shortening gets its own 10% slice if enabled
        let silenceScale = options.shortenSilences ? 0.10 : 0.0
        let auNormScale  = encodingMP3 ? (0.85 - silenceScale) : (1.0 - silenceScale)

        // WAV path used throughout AU/normalization pipeline
        var wavOutputPath: String
        var temps: [String] = []

        func makeTempPath() -> String {
            let p = URL(fileURLWithPath: outputPath)
                .deletingLastPathComponent()
                .appendingPathComponent("dechaff_tmp_\(UUID().uuidString).wav").path
            temps.append(p)
            return p
        }

        if encodingMP3 {
            // Final output is MP3, so all intermediate WAV work goes to a temp file
            wavOutputPath = makeTempPath()
        } else {
            wavOutputPath = outputPath
        }

        // Temp WAV needed between AU pass and normalization
        let auOutputPath: String
        if needsAU && options.normalization {
            auOutputPath = makeTempPath()
        } else {
            auOutputPath = wavOutputPath
        }

        // Pass 1: isolation + compression
        if needsAU {
            let p1End = options.normalization ? 0.65 * auNormScale : auNormScale
            let ok = runAUPass(audioFile: audioFile, outputPath: auOutputPath,
                               options: options, progressStart: 0.0, progressEnd: p1End)
            guard ok else { temps.forEach(cleanup); return false }
        }

        // Pass 2: normalization
        if options.normalization {
            let measureSource = needsAU ? auOutputPath : inputPath
            let pStart = needsAU ? 0.65 * auNormScale : 0.0
            let pMid   = needsAU ? 0.85 * auNormScale : 0.7 * auNormScale
            // When needsAU=true the AU output is already trimmed — pass empty options so measureLUFS
            // reads the whole file rather than trying to seek to original-file positions.
            let measureOptions = needsAU ? ProcessingOptions() : options
            guard let measured = measureLUFS(path: measureSource, options: measureOptions,
                                             progressStart: pStart, progressEnd: pMid) else {
                logHandler("❌ Loudness measurement failed — skipping normalization")
                temps.forEach(cleanup); return false
            }
            let gainDB = options.targetLUFS - measured
            logHandler(String(format: "Measured %.1f LUFS → target %.1f LUFS (%+.1f dB)",
                               measured, options.targetLUFS, gainDB))
            let ok = applyGain(inputPath: measureSource, outputPath: wavOutputPath,
                               gainDB: gainDB, targetLUFS: options.targetLUFS,
                               monoOutput: !needsAU && options.monoOutput,
                               options: needsAU ? ProcessingOptions() : options,
                               progressStart: pMid, progressEnd: auNormScale)
            guard ok else { temps.forEach(cleanup); return false }
            // Remove the AU temp (if different from wav output)
            if auOutputPath != wavOutputPath { cleanup(auOutputPath) }
        }

        // Pass 2.5: silence shortening (on normalized WAV, before MP3 encode)
        if options.shortenSilences {
            if let segments = detectSilences(inputPath: wavOutputPath, maxKept: options.maxSilenceDuration) {
                detectedSilenceSegments = segments
                let totalRemovable = segments.reduce(0.0) {
                    $0 + max(0, ($1.endSeconds - $1.startSeconds) - $1.keptSeconds)
                }
                if totalRemovable > 0 {
                    let silenceWavPath = makeTempPath()
                    let ok = shortenSilenceFrames(inputPath: wavOutputPath, outputPath: silenceWavPath,
                                                  segments: segments,
                                                  progressStart: auNormScale,
                                                  progressEnd: auNormScale + silenceScale)
                    guard ok else { temps.forEach(cleanup); return false }
                    if encodingMP3 {
                        cleanup(wavOutputPath)
                        wavOutputPath = silenceWavPath
                    } else {
                        let finalPath = wavOutputPath
                        do {
                            try FileManager.default.removeItem(atPath: finalPath)
                            try FileManager.default.moveItem(atPath: silenceWavPath, toPath: finalPath)
                            temps.removeAll { $0 == silenceWavPath }
                        } catch {
                            logHandler("⚠️ Could not finalize shortened audio: \(error.localizedDescription)")
                        }
                    }
                } else {
                    logHandler("✂️ No long silences detected")
                    progressHandler(auNormScale + silenceScale)
                }
            } else {
                logHandler("⚠️ Silence detection failed — skipping")
                progressHandler(auNormScale + silenceScale)
            }
        } else {
            detectedSilenceSegments = []
        }

        // Pass 3: MP3 encoding
        if encodingMP3 {
            let ok = encodeToMP3(inputWAV: wavOutputPath, outputMP3: outputPath,
                                 bitrate: options.mp3Bitrate, mono: options.monoOutput,
                                 progressStart: auNormScale, progressEnd: 1.0)
            cleanup(wavOutputPath)
            return ok
        }

        return true
    }

    // MARK: - ID3v2 tagging

    /// Write (or rewrite) all ID3 tags — metadata, artwork, and chapters — into an existing MP3.
    func writeTags(chapters: [Chapter], metadata: ID3Metadata, to mp3Path: String,
                   logHandler: @escaping (String) -> Void) {
        self.logHandler = logHandler
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: mp3Path)) else {
            logHandler("⚠️ Could not read file for tagging"); return
        }
        let durationMs = UInt32((Double(file.length) / file.fileFormat.sampleRate) * 1000.0)
        let url = URL(fileURLWithPath: mp3Path)
        guard var mp3Data = try? Data(contentsOf: url) else {
            logHandler("⚠️ Could not read MP3 for tagging"); return
        }
        mp3Data = stripID3v2Header(from: mp3Data)
        var output = buildID3v2Tag(chapters: chapters, metadata: metadata, durationMs: durationMs)
        output.append(mp3Data)
        do {
            try output.write(to: url, options: .atomic)
            var parts: [String] = []
            if !chapters.isEmpty { parts.append("\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")") }
            if metadata.artwork != nil { parts.append("artwork") }
            let hasText = !metadata.title.isEmpty || !metadata.artist.isEmpty || !metadata.album.isEmpty
            if hasText { parts.append("tags") }
            logHandler("🔖 Saved \(parts.isEmpty ? "ID3 tag" : parts.joined(separator: ", "))")
        } catch {
            logHandler("⚠️ Tag write failed: \(error.localizedDescription)")
        }
    }

    private func buildID3v2Tag(chapters: [Chapter], metadata: ID3Metadata, durationMs: UInt32) -> Data {
        var frames = Data()

        // Text frames
        if !metadata.title.isEmpty  { frames.append(makeTextFrame("TIT2", metadata.title)) }
        if !metadata.artist.isEmpty { frames.append(makeTextFrame("TPE1", metadata.artist)) }
        if !metadata.album.isEmpty  { frames.append(makeTextFrame("TALB", metadata.album)) }
        if !metadata.year.isEmpty   { frames.append(makeTextFrame("TYER", metadata.year)) }

        // Album art (APIC — Cover front)
        if let art = metadata.artwork {
            var body = Data([0x00])                    // encoding: Latin-1 (for MIME string)
            body.append(contentsOf: "image/jpeg".utf8)
            body.append(0x00)                          // null-terminate MIME
            body.append(0x03)                          // picture type: Cover (front)
            body.append(0x00)                          // description: empty, null-terminated
            body.append(art)
            frames.append(makeID3Frame(id: "APIC", body: body))
        }

        // Chapter frames
        if !chapters.isEmpty {
            let sorted = chapters.sorted { $0.timeSeconds < $1.timeSeconds }
            let chapIDs = sorted.indices.map { "ch\($0)" }

            var ctoc = Data()
            ctoc.append(contentsOf: "toc".utf8); ctoc.append(0x00)
            ctoc.append(0x03)
            ctoc.append(UInt8(sorted.count))
            for cid in chapIDs { ctoc.append(contentsOf: cid.utf8); ctoc.append(0x00) }
            frames.append(makeID3Frame(id: "CTOC", body: ctoc))

            for (i, chapter) in sorted.enumerated() {
                let startMs = UInt32(max(0, chapter.timeSeconds) * 1000)
                let endMs   = i + 1 < sorted.count
                    ? UInt32(max(0, sorted[i + 1].timeSeconds) * 1000) : durationMs
                var chap = Data()
                chap.append(contentsOf: chapIDs[i].utf8); chap.append(0x00)
                chap.append(contentsOf: toBE32(startMs))
                chap.append(contentsOf: toBE32(endMs))
                chap.append(contentsOf: toBE32(0xFFFF_FFFF))
                chap.append(contentsOf: toBE32(0xFFFF_FFFF))
                if !chapter.title.isEmpty {
                    var tit2 = Data([0x03])
                    tit2.append(contentsOf: chapter.title.utf8)
                    chap.append(makeID3Frame(id: "TIT2", body: tit2))
                }
                frames.append(makeID3Frame(id: "CHAP", body: chap))
            }
        }

        var tag = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        tag.append(contentsOf: toSyncsafe32(UInt32(frames.count)))
        tag.append(frames)
        return tag
    }

    private func makeTextFrame(_ id: String, _ text: String) -> Data {
        var body = Data([0x03])  // UTF-8
        body.append(contentsOf: text.utf8)
        return makeID3Frame(id: id, body: body)
    }

    /// Builds a single ID3v2.3 frame. Frame size is plain big-endian (NOT syncsafe — that's v2.4).
    private func makeID3Frame(id: String, body: Data) -> Data {
        var frame = Data(id.utf8.prefix(4))
        frame.append(contentsOf: toBE32(UInt32(body.count)))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(body)
        return frame
    }

    private func stripID3v2Header(from data: Data) -> Data {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return data }
        let size = (UInt32(data[6] & 0x7F) << 21) | (UInt32(data[7] & 0x7F) << 14)
                 | (UInt32(data[8] & 0x7F) <<  7) |  UInt32(data[9] & 0x7F)
        let end = Int(10 + size)
        guard end <= data.count else { return data }
        return data.subdata(in: end..<data.count)
    }

    private func toBE32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private func toSyncsafe32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }

    // MARK: - MP3 encoding via bundled LAME

    private func encodeToMP3(inputWAV: String, outputMP3: String, bitrate: Int, mono: Bool,
                             progressStart: Double, progressEnd: Double) -> Bool {
        guard let lamePath = Bundle.main.path(forResource: "lame", ofType: nil) else {
            logHandler("❌ Bundled LAME binary not found"); return false
        }

        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lamePath)

        let monoLabel = mono ? " mono" : ""
        logHandler("🎵 Encoding MP3 (\(bitrate)kbps\(monoLabel))…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lamePath)
        var args = ["-b", "\(bitrate)", "--cbr", "--silent"]
        if mono { args += ["-m", "m"] }
        args += [inputWAV, outputMP3]
        process.arguments = args

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logHandler("❌ LAME failed to launch: \(error.localizedDescription)"); return false
        }

        if process.terminationStatus == 0 {
            // Get output file size for logging
            let size = (try? FileManager.default.attributesOfItem(atPath: outputMP3)[.size] as? Int) ?? 0
            logHandler(String(format: "✅ MP3 encoded — %.1f MB", Double(size) / 1_048_576))
            progressHandler(1.0)
            return true
        } else {
            let errOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logHandler("❌ LAME error: \(errOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            return false
        }
    }

    // MARK: - File loading

    private func loadAudioFile(path: String) -> AVAudioFile? {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let dur = Double(file.length) / file.fileFormat.sampleRate
            logHandler(String(format: "Loaded: %.1fs · %dHz · %dch",
                               dur, Int(file.fileFormat.sampleRate), file.fileFormat.channelCount))
            return file
        } catch {
            logHandler("❌ Failed to load: \(error.localizedDescription)"); return nil
        }
    }

    // MARK: - AU pass (isolation + compression)

    private func runAUPass(audioFile: AVAudioFile, outputPath: String,
                           options: ProcessingOptions,
                           progressStart: Double, progressEnd: Double) -> Bool {
        let format = audioFile.processingFormat
        var isolationAU: AudioUnit? = nil
        var compressorAU: AudioUnit? = nil

        if options.voiceIsolation {
            guard let au = makeAU(subType: isolationSubType, format: format) else { return false }
            AudioUnitSetParameter(au, 0,     kAudioUnitScope_Global, 0, 100.0, 0)
            AudioUnitSetParameter(au, 95782, kAudioUnitScope_Global, 0, 1.0,   0)
            AudioUnitSetParameter(au, 95783, kAudioUnitScope_Global, 0, 1.0,   0)
            guard AudioUnitInitialize(au) == noErr else {
                logHandler("❌ Isolation AU init failed")
                AudioComponentInstanceDispose(au); return false
            }
            logHandler("Voice isolation ready")
            isolationAU = au
        }

        if options.compression {
            guard let au = makeAU(subType: kAudioUnitSubType_DynamicsProcessor, format: format) else {
                isolationAU.map { AudioUnitUninitialize($0); AudioComponentInstanceDispose($0) }
                return false
            }
            // Threshold -28 dB: catches the quieter Bible reader as well as loud preacher peaks
            // HeadRoom 20 dB: wide soft knee — gradual onset avoids pumping on natural speech variation
            // AttackTime 5ms: fast enough to level speaker-to-speaker changes without clipping transients
            // ReleaseTime 200ms: slow enough to avoid rapid gain pumping between sentences
            AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold,     kAudioUnitScope_Global, 0, -28.0, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom,      kAudioUnitScope_Global, 0, 20.0,  0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime,    kAudioUnitScope_Global, 0,  0.005, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime,   kAudioUnitScope_Global, 0,  0.2,  0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain,   kAudioUnitScope_Global, 0,  0.0,  0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_ExpansionRatio,kAudioUnitScope_Global, 0,  1.0,  0)
            guard AudioUnitInitialize(au) == noErr else {
                logHandler("❌ Compressor AU init failed")
                AudioComponentInstanceDispose(au)
                isolationAU.map { AudioUnitUninitialize($0); AudioComponentInstanceDispose($0) }
                return false
            }
            logHandler("Dynamics compressor ready")
            compressorAU = au
        }

        defer {
            isolationAU.map { AudioUnitUninitialize($0); AudioComponentInstanceDispose($0) }
            compressorAU.map { AudioUnitUninitialize($0); AudioComponentInstanceDispose($0) }
        }

        return renderLoop(audioFile: audioFile, outputPath: outputPath,
                          isolationAU: isolationAU, compressorAU: compressorAU,
                          options: options, progressStart: progressStart, progressEnd: progressEnd)
    }

    private func makeAU(subType: UInt32, format: AVAudioFormat) -> AudioUnit? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            logHandler("❌ AU not found (0x\(String(subType, radix: 16)))"); return nil
        }
        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let au else {
            logHandler("❌ Could not instantiate AU"); return nil
        }
        var fmt = format.streamDescription.pointee
        var maxFrames: UInt32 = 4096
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,  0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        return au
    }

    private func renderLoop(audioFile: AVAudioFile, outputPath: String,
                            isolationAU: AudioUnit?, compressorAU: AudioUnit?,
                            options: ProcessingOptions,
                            progressStart: Double, progressEnd: Double) -> Bool {
        do {
            let format = audioFile.processingFormat
            let doMono = options.monoOutput && format.channelCount > 1
            let monoFmt = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
            var outSettings = format.settings
            outSettings.removeValue(forKey: AVChannelLayoutKey)  // channel layout from M4A/AAC is not WAV-compatible
            if doMono { outSettings[AVNumberOfChannelsKey] = 1 }
            let outFile = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath), settings: outSettings)

            let frameCount: AVAudioFrameCount = 4096
            // All AU rendering uses stereo buffers matching the processing format.
            // Mono conversion happens only at write time to avoid AU buffer mismatch.
            guard let inBuf  = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                  let midBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                logHandler("❌ Buffer allocation failed"); return false
            }
            let monoBuf: AVAudioPCMBuffer? = doMono
                ? AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: frameCount)
                : nil

            let sr = format.sampleRate
            let inFrame  = AVAudioFramePosition(options.trimInSeconds * sr)
            let outFrame = min(options.trimOutSeconds > 0
                ? AVAudioFramePosition(options.trimOutSeconds * sr)
                : audioFile.length, audioFile.length)
            let trimLength = AVAudioFrameCount(max(0, outFrame - inFrame))
            var totalFrames: AVAudioFrameCount = 0
            let startTime = Date()
            audioFile.framePosition = inFrame

            while totalFrames < trimLength {
                let toRead = min(frameCount, trimLength - totalFrames)
                inBuf.frameLength = toRead
                try audioFile.read(into: inBuf, frameCount: toRead)
                guard inBuf.frameLength > 0 else { break }

                var current: AVAudioPCMBuffer = inBuf

                if let au = isolationAU {
                    midBuf.frameLength = inBuf.frameLength
                    guard renderAU(au, from: current, into: midBuf, sampleTime: Float64(totalFrames)) else {
                        logHandler("❌ Isolation render failed"); return false
                    }
                    current = midBuf
                }

                if let au = compressorAU {
                    outBuf.frameLength = current.frameLength
                    guard renderAU(au, from: current, into: outBuf, sampleTime: Float64(totalFrames)) else {
                        logHandler("❌ Compressor render failed"); return false
                    }
                    current = outBuf
                }

                if let mono = monoBuf {
                    mono.frameLength = current.frameLength
                    convertToMono(src: current, dst: mono)
                    try outFile.write(from: mono)
                } else {
                    try outFile.write(from: current)
                }

                totalFrames += inBuf.frameLength
                progressHandler(progressStart + (progressEnd - progressStart) * Double(totalFrames) / Double(trimLength))
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let speedup = (Double(trimLength) / sr) / elapsed
            logHandler(String(format: "AU pass done in %.1fs (%.1f×)", elapsed, speedup))
            return true
        } catch {
            logHandler("❌ Render error: \(error.localizedDescription)"); return false
        }
    }

    private func renderAU(_ au: AudioUnit, from input: AVAudioPCMBuffer,
                           into output: AVAudioPCMBuffer, sampleTime: Float64) -> Bool {
        let cb: AURenderCallback = { inRefCon, _, _, _, _, ioData in
            guard let ioData else { return -1 }
            let src = inRefCon.assumingMemoryBound(to: AudioBufferList.self)
            return withUnsafePointer(to: &src.pointee.mBuffers) { srcPtr in
                let s = UnsafeBufferPointer<AudioBuffer>(start: srcPtr, count: Int(src.pointee.mNumberBuffers))
                return withUnsafeMutablePointer(to: &ioData.pointee.mBuffers) { dstPtr in
                    let d = UnsafeMutableBufferPointer<AudioBuffer>(start: dstPtr, count: Int(ioData.pointee.mNumberBuffers))
                    for i in 0..<min(s.count, d.count) { d[i].mData = s[i].mData; d[i].mDataByteSize = s[i].mDataByteSize }
                    return noErr
                }
            }
        }
        var cbs = AURenderCallbackStruct(inputProc: cb,
                                         inputProcRefCon: UnsafeMutableRawPointer(mutating: input.audioBufferList))
        guard AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                   kAudioUnitScope_Input, 0, &cbs,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else { return false }
        output.frameLength = input.frameLength
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime; ts.mFlags = .sampleTimeValid
        return AudioUnitRender(au, &flags, &ts, 0, input.frameLength, output.mutableAudioBufferList) == noErr
    }

    // MARK: - EBU R128 loudness measurement

    private final class BiquadCascade {
        private let setup: vDSP_biquad_Setup
        private var delay: [Float]
        init(s1: [Double], s2: [Double]) {
            setup = vDSP_biquad_CreateSetup(s1 + s2, 2)!  // 2 sections
            delay = [Float](repeating: 0, count: 6)        // 2*M+2
        }
        deinit { vDSP_biquad_DestroySetup(setup) }
        func apply(input: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: input.count)
            vDSP_biquad(setup, &delay, input, 1, &out, 1, vDSP_Length(input.count))
            return out
        }
    }

    private func measureLUFS(path: String, options: ProcessingOptions,
                             progressStart: Double, progressEnd: Double) -> Double? {
        logHandler("📏 Measuring loudness (EBU R128)…")
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let sr = file.processingFormat.sampleRate
            let nch = Int(file.processingFormat.channelCount)
            let (s1, s2) = kWeightingCoefficients(sampleRate: sr)
            let filters = (0..<nch).map { _ in BiquadCascade(s1: s1.map(Double.init), s2: s2.map(Double.init)) }

            let chunkSize: AVAudioFrameCount = 4096
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else { return nil }
            var kw = Array(repeating: [Float](), count: nch)
            let inFrame  = AVAudioFramePosition(options.trimInSeconds * sr)
            let outFrame = min(options.trimOutSeconds > 0
                ? AVAudioFramePosition(options.trimOutSeconds * sr)
                : file.length, file.length)
            let trimLength = AVAudioFrameCount(max(0, outFrame - inFrame))
            var readFrames: AVAudioFrameCount = 0
            file.framePosition = inFrame

            while readFrames < trimLength {
                let toRead = min(chunkSize, trimLength - readFrames)
                buf.frameLength = toRead
                try file.read(into: buf, frameCount: toRead)
                guard buf.frameLength > 0 else { break }
                for ch in 0..<nch {
                    guard let data = buf.floatChannelData?[ch] else { continue }
                    let samples = Array(UnsafeBufferPointer(start: data, count: Int(buf.frameLength)))
                    kw[ch].append(contentsOf: filters[ch].apply(input: samples))

                }
                readFrames += buf.frameLength
                progressHandler(progressStart + (progressEnd - progressStart) * 0.7 * Double(readFrames) / Double(trimLength))
            }

            let total = kw[0].count
            let blockSize = max(1, Int(sr * 0.4))
            let hopSize   = max(1, Int(sr * 0.1))
            var blocks = [Double]()
            var pos = 0
            while pos + blockSize <= total {
                var sumMS = 0.0
                for ch in 0..<nch {
                    var ms: Float = 0
                    kw[ch].withUnsafeBufferPointer { ptr in
                        vDSP_measqv(ptr.baseAddress! + pos, 1, &ms, vDSP_Length(blockSize))
                    }
                    sumMS += Double(ms)
                }
                blocks.append(-0.691 + 10.0 * log10(max(sumMS, 1e-10)))
                pos += hopSize
            }

            guard !blocks.isEmpty else { logHandler("⚠️ EBU R128: no blocks — \(total) samples read (file too short?)"); return nil }
            progressHandler(progressStart + (progressEnd - progressStart) * 0.9)

            // Absolute gate −70 LUFS
            let gated1 = blocks.filter { $0 > -70.0 }
            guard !gated1.isEmpty else { logHandler("⚠️ Signal too quiet"); return nil }
            let mean1 = gated1.map { pow(10.0, ($0 + 0.691) / 10.0) }.reduce(0, +) / Double(gated1.count)
            let lufs1 = -0.691 + 10.0 * log10(mean1)

            // Relative gate lufs1 − 10
            let gated2 = gated1.filter { $0 > lufs1 - 10.0 }
            guard !gated2.isEmpty else { return lufs1 }
            let mean2 = gated2.map { pow(10.0, ($0 + 0.691) / 10.0) }.reduce(0, +) / Double(gated2.count)
            return -0.691 + 10.0 * log10(mean2)
        } catch {
            logHandler("❌ Measurement failed: \(error.localizedDescription)"); return nil
        }
    }

    private func kWeightingCoefficients(sampleRate: Double) -> ([Float], [Float]) {
        // Stage 1: high-shelf (ITU-R BS.1770-4 pre-filter)
        let Vb = pow(10.0, 3.99984385397 / 20.0)
        let K1 = tan(.pi * 1681.974450955533 / sampleRate), K1sq = K1 * K1
        let d1 = 1.0 + sqrt(2.0) * K1 + K1sq
        let s1: [Float] = [
            Float((Vb + sqrt(2.0 * Vb) * K1 + K1sq) / d1),
            Float(2.0 * (K1sq - Vb) / d1),
            Float((Vb - sqrt(2.0 * Vb) * K1 + K1sq) / d1),
            Float(2.0 * (K1sq - 1.0) / d1),
            Float((1.0 - sqrt(2.0) * K1 + K1sq) / d1)
        ]
        // Stage 2: high-pass RLB weighting
        let Q2 = 0.5003270373238773
        let K2 = tan(.pi * 38.13547087602444 / sampleRate), K2sq = K2 * K2
        let d2 = 1.0 + K2 / Q2 + K2sq
        let s2: [Float] = [
            Float(1.0 / d2), Float(-2.0 / d2), Float(1.0 / d2),
            Float(2.0 * (K2sq - 1.0) / d2),
            Float((1.0 - K2 / Q2 + K2sq) / d2)
        ]
        return (s1, s2)
    }

    // MARK: - Gain application

    private func applyGain(inputPath: String, outputPath: String, gainDB: Double, targetLUFS: Double,
                           monoOutput: Bool, options: ProcessingOptions,
                           progressStart: Double, progressEnd: Double) -> Bool {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
            let fmt = file.processingFormat
            var outSettings = fmt.settings
            outSettings.removeValue(forKey: AVChannelLayoutKey)  // channel layout from M4A/AAC is not WAV-compatible
            if monoOutput { outSettings[AVNumberOfChannelsKey] = 1 }
            let outFile = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath), settings: outSettings)
            let outFmt = monoOutput ? AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 1)! : fmt
            var gain = Float(pow(10.0, gainDB / 20.0))

            let chunkSize: AVAudioFrameCount = 4096
            guard let buf    = AVAudioPCMBuffer(pcmFormat: fmt,    frameCapacity: chunkSize),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunkSize) else { return false }
            let sr = fmt.sampleRate
            let inFrame  = AVAudioFramePosition(options.trimInSeconds * sr)
            let outFrame = min(options.trimOutSeconds > 0
                ? AVAudioFramePosition(options.trimOutSeconds * sr)
                : file.length, file.length)
            let trimLength = AVAudioFrameCount(max(0, outFrame - inFrame))
            var totalFrames: AVAudioFrameCount = 0
            file.framePosition = inFrame

            while totalFrames < trimLength {
                let toRead = min(chunkSize, trimLength - totalFrames)
                buf.frameLength = toRead
                try file.read(into: buf, frameCount: toRead)
                guard buf.frameLength > 0 else { break }
                for ch in 0..<Int(fmt.channelCount) {
                    guard let data = buf.floatChannelData?[ch] else { continue }
                    vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(buf.frameLength))
                }
                if monoOutput && fmt.channelCount > 1 {
                    outBuf.frameLength = buf.frameLength
                    convertToMono(src: buf, dst: outBuf)
                    try outFile.write(from: outBuf)
                } else {
                    try outFile.write(from: buf)
                }
                totalFrames += buf.frameLength
                progressHandler(progressStart + (progressEnd - progressStart) * Double(totalFrames) / Double(trimLength))
            }
            logHandler(String(format: "✅ Normalized to %.1f LUFS", targetLUFS))
            return true
        } catch {
            logHandler("❌ Gain pass failed: \(error.localizedDescription)"); return false
        }
    }

    // MARK: - Silence detection and shortening

    private func detectSilences(inputPath: String, maxKept: Double) -> [SilenceSegment]? {
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

    private func shortenSilenceFrames(inputPath: String, outputPath: String,
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

    // MARK: - Helpers

    private func convertToMono(src: AVAudioPCMBuffer, dst: AVAudioPCMBuffer) {
        let n = Int(src.frameLength)
        guard Int(src.format.channelCount) > 1,
              let s = src.floatChannelData, let d = dst.floatChannelData else { return }
        memcpy(d[0], s[min(1, Int(src.format.channelCount) - 1)], n * MemoryLayout<Float>.size)
        dst.frameLength = src.frameLength
    }

    private func cleanup(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
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
