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
    var slowLeveler: Bool = false          // windowed RMS gain envelope
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
        let levelerActive = options.slowLeveler

        // Scale AU+normalization progress; silence shortening gets its own 10% slice if enabled
        let silenceScale = options.shortenSilences ? 0.10 : 0.0
        let auNormScale  = encodingMP3 ? (0.85 - silenceScale) : (1.0 - silenceScale)

        // Progress fractions (of auNormScale) — compress AU slightly when leveler is active
        let p_auEnd:   Double = levelerActive ? 0.45 : 0.65  // end of AU pass
        let p_levEnd:  Double = 0.60                          // end of leveler (= norm start)
        let p_measEnd: Double = levelerActive ? 0.78 : 0.85  // end of LUFS measurement

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
            wavOutputPath = makeTempPath()
        } else {
            wavOutputPath = outputPath
        }

        // Temp WAV needed when a downstream pass follows the AU pass
        let auOutputPath: String
        if needsAU && (options.normalization || levelerActive) {
            auOutputPath = makeTempPath()
        } else {
            auOutputPath = wavOutputPath
        }

        // Pass 1: isolation + compression
        if needsAU {
            let p1End = (options.normalization || levelerActive) ? p_auEnd * auNormScale : auNormScale
            let ok = runAUPass(audioFile: audioFile, outputPath: auOutputPath,
                               options: options, progressStart: 0.0, progressEnd: p1End)
            guard ok else { temps.forEach(cleanup); return false }
        }

        // Pass 1.5: slow leveler — after AU (or directly from input), before normalization.
        // Builds a smooth per-sample gain envelope from 1-second window RMS measurements,
        // clamped to ±6 dB, to even out sustained level differences between speakers.
        var normSource: String = needsAU ? auOutputPath : inputPath
        if levelerActive {
            let levelerPath = options.normalization ? makeTempPath() : wavOutputPath
            let lStart = needsAU ? p_auEnd * auNormScale : 0.0
            let lEnd   = needsAU ? p_levEnd * auNormScale
                                 : (options.normalization ? 0.25 * auNormScale : auNormScale)
            let ok = applySlowLeveler(inputPath: normSource, outputPath: levelerPath,
                                      progressStart: lStart, progressEnd: lEnd)
            guard ok else { temps.forEach(cleanup); return false }
            if normSource != inputPath { cleanup(normSource) }
            normSource = levelerPath
        }

        // Pass 2: normalization
        if options.normalization {
            let pStart = needsAU ? p_levEnd * auNormScale
                                 : (levelerActive ? 0.25 * auNormScale : 0.0)
            let pMid   = needsAU ? p_measEnd * auNormScale
                                 : (levelerActive ? 0.65 * auNormScale : 0.7 * auNormScale)
            // AU output is already trimmed — pass empty options so measureLUFS reads the whole file
            let measureOptions = needsAU ? ProcessingOptions() : options
            guard let measured = measureLUFS(path: normSource, options: measureOptions,
                                             progressStart: pStart, progressEnd: pMid) else {
                logHandler("❌ Loudness measurement failed — skipping normalization")
                temps.forEach(cleanup); return false
            }
            let gainDB = options.targetLUFS - measured
            logHandler(String(format: "Measured %.1f LUFS → target %.1f LUFS (%+.1f dB)",
                               measured, options.targetLUFS, gainDB))
            let ok = applyGain(inputPath: normSource, outputPath: wavOutputPath,
                               gainDB: gainDB, targetLUFS: options.targetLUFS,
                               monoOutput: !needsAU && options.monoOutput,
                               options: needsAU ? ProcessingOptions() : options,
                               progressStart: pMid, progressEnd: auNormScale)
            guard ok else { temps.forEach(cleanup); return false }
            if normSource != wavOutputPath { cleanup(normSource) }
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
        } catch {
            logHandler("❌ LAME failed to launch: \(error.localizedDescription)"); return false
        }

        // Drain the pipe before waitUntilExit to prevent deadlock:
        // if LAME writes enough to fill the pipe buffer (~64 KB), it blocks
        // waiting for the reader, but waitUntilExit blocks waiting for LAME.
        let pipeData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            // Get output file size for logging
            let size = (try? FileManager.default.attributesOfItem(atPath: outputMP3)[.size] as? Int) ?? 0
            logHandler(String(format: "✅ MP3 encoded — %.1f MB", Double(size) / 1_048_576))
            progressHandler(1.0)
            return true
        } else {
            let errOutput = String(data: pipeData, encoding: .utf8) ?? ""
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
            // Threshold -28 dB: engages on all speech, including the quieter scripture reader
            // HeadRoom 6 dB: ceiling = -22 dBFS before makeup — gives ~4.7:1 effective ratio,
            //   which is standard for podcast voice and meaningfully reduces crest factor
            // OverallGain +8 dB: makeup gain to raise the compressed output level, reducing
            //   the gap that loudness normalisation has to close
            // AttackTime 3ms: fast enough to catch peaks without biting into transients
            // ReleaseTime 150ms: snappy enough to stay tight without audible pumping
            AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold,     kAudioUnitScope_Global, 0, -28.0, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom,      kAudioUnitScope_Global, 0,  6.0,  0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime,    kAudioUnitScope_Global, 0,  0.003, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime,   kAudioUnitScope_Global, 0,  0.15,  0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain,   kAudioUnitScope_Global, 0,  8.0,  0)
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

    /// Static render callback — avoids a closure allocation per chunk.
    /// The refcon is updated via AudioUnitSetProperty before each render call.
    private static let auRenderCallback: AURenderCallback = { inRefCon, _, _, _, _, ioData in
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

    private func renderAU(_ au: AudioUnit, from input: AVAudioPCMBuffer,
                           into output: AVAudioPCMBuffer, sampleTime: Float64) -> Bool {
        var cbs = AURenderCallbackStruct(inputProc: Self.auRenderCallback,
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

    // MARK: - Slow leveler

    /// Builds a smooth per-sample gain envelope from 1-second window RMS measurements,
    /// clamped to ±6 dB, to even out sustained level differences (e.g. quiet scripture
    /// reader → loud preacher) without audible pumping.
    ///
    /// Algorithm:
    ///  1. Measure RMS per 1-second window across all channels.
    ///  2. Use the median voiced-window RMS as the reference level.
    ///  3. Compute per-window gain = clamp(ref / rms, −6 dB … +6 dB); silent windows → unity.
    ///  4. Smooth with a zero-phase forward + backward EMA (α = 0.25, ≈ 3 s time constant).
    ///  5. Apply with a linear ramp across each window (continuity guaranteed at boundaries).
    private func applySlowLeveler(inputPath: String, outputPath: String,
                                   progressStart: Double, progressEnd: Double) -> Bool {
        logHandler("📊 Building slow gain envelope…")
        let maxGainDB: Float = 6.0
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
            let fmt  = file.processingFormat
            let sr   = fmt.sampleRate
            let nch  = Int(fmt.channelCount)
            let totalFrames = Int(file.length)
            guard totalFrames > 0 else { return true }

            let windowFrames = Int(sr)   // 1-second windows
            let nWindows = (totalFrames + windowFrames - 1) / windowFrames

            // ── Pass 1: RMS per window ────────────────────────────────────────
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                             frameCapacity: AVAudioFrameCount(windowFrames)) else { return false }
            var windowRMS = [Float](repeating: 0, count: nWindows)

            file.framePosition = 0
            for w in 0..<nWindows {
                let toRead = AVAudioFrameCount(min(windowFrames, totalFrames - w * windowFrames))
                buf.frameLength = toRead
                try file.read(into: buf, frameCount: toRead)
                guard buf.frameLength > 0 else { break }
                var sumMS: Float = 0
                for ch in 0..<nch {
                    guard let d = buf.floatChannelData?[ch] else { continue }
                    var ms: Float = 0
                    vDSP_measqv(d, 1, &ms, vDSP_Length(buf.frameLength))
                    sumMS += ms
                }
                windowRMS[w] = sqrt(max(sumMS / Float(nch), 0))
                progressHandler(progressStart + (progressEnd - progressStart) * 0.4 * Double(w + 1) / Double(nWindows))
            }

            // ── Build gain map ────────────────────────────────────────────────
            let noiseFloor: Float = Float(pow(10.0, -50.0 / 20.0))   // –50 dBFS
            let maxLinear  = Float(pow(10.0, Double(maxGainDB) / 20.0))
            let minLinear  = 1.0 / maxLinear

            // Reference: median RMS of windows above the noise floor
            let voiced = windowRMS.filter { $0 > noiseFloor }
            guard !voiced.isEmpty else {
                logHandler("⚠️ Slow leveler: signal below noise floor, skipping")
                try FileManager.default.copyItem(atPath: inputPath, toPath: outputPath)
                return true
            }
            let reference = voiced.sorted()[voiced.count / 2]

            var gainMap = [Float](repeating: 1.0, count: nWindows)
            for w in 0..<nWindows where windowRMS[w] > noiseFloor {
                gainMap[w] = max(minLinear, min(maxLinear, reference / max(windowRMS[w], 1e-10)))
            }

            // ── Smooth: zero-phase forward + backward EMA (~3 s time constant) ──
            let alpha: Float = 0.25
            for i in 1..<nWindows {
                gainMap[i] = alpha * gainMap[i] + (1 - alpha) * gainMap[i - 1]
            }
            for i in stride(from: nWindows - 2, through: 0, by: -1) {
                gainMap[i] = alpha * gainMap[i] + (1 - alpha) * gainMap[i + 1]
            }

            let minG = gainMap.min() ?? 1, maxG = gainMap.max() ?? 1
            logHandler(String(format: "📊 Leveler gain range: %+.1f dB to %+.1f dB",
                              20.0 * log10(Double(minG)), 20.0 * log10(Double(maxG))))

            // ── Pass 2: apply gain with per-window linear ramp ────────────────
            var outSettings = fmt.settings
            outSettings.removeValue(forKey: AVChannelLayoutKey)
            let outFile = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath), settings: outSettings)

            guard let writeBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                                                  frameCapacity: AVAudioFrameCount(windowFrames)) else { return false }
            file.framePosition = 0
            for w in 0..<nWindows {
                let toRead = AVAudioFrameCount(min(windowFrames, totalFrames - w * windowFrames))
                buf.frameLength = toRead
                try file.read(into: buf, frameCount: toRead)
                guard buf.frameLength > 0 else { break }
                writeBuf.frameLength = buf.frameLength
                let n = vDSP_Length(buf.frameLength)

                // Ramp from midpoint(prev, this) to midpoint(this, next) — no discontinuity at boundaries
                var gStart = ((w > 0 ? gainMap[w - 1] : gainMap[w]) + gainMap[w]) * 0.5
                var gEnd   = (gainMap[w] + (w + 1 < nWindows ? gainMap[w + 1] : gainMap[w])) * 0.5
                var gainRamp = [Float](repeating: 0, count: Int(n))
                vDSP_vgen(&gStart, &gEnd, &gainRamp, 1, n)

                for ch in 0..<nch {
                    guard let inD  = buf.floatChannelData?[ch],
                          let outD = writeBuf.floatChannelData?[ch] else { continue }
                    vDSP_vmul(inD, 1, gainRamp, 1, outD, 1, n)
                }
                try outFile.write(from: writeBuf)
                progressHandler(progressStart + (progressEnd - progressStart) * (0.4 + 0.6 * Double(w + 1) / Double(nWindows)))
            }
            logHandler("✅ Slow leveler applied")
            return true
        } catch {
            logHandler("❌ Slow leveler failed: \(error.localizedDescription)"); return false
        }
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

            let blockSize = max(1, Int(sr * 0.4))
            let hopSize   = max(1, Int(sr * 0.1))

            // Streaming buffer: holds only enough K-weighted samples to form overlapping
            // 400ms blocks. Peak size is bounded to ~blockSize + chunkSize per channel
            // (~93 KB for stereo 48 kHz) instead of the entire file (~2 GB for 90 min).
            var kwBuf = Array(repeating: [Float](), count: nch)
            var kwOffset = 0
            var blocks = [Double]()

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
                    kwBuf[ch].append(contentsOf: filters[ch].apply(input: samples))
                }
                readFrames += buf.frameLength

                // Compute loudness blocks as soon as enough samples are available
                while kwBuf[0].count - kwOffset >= blockSize {
                    var sumMS = 0.0
                    for ch in 0..<nch {
                        var ms: Float = 0
                        kwBuf[ch].withUnsafeBufferPointer { ptr in
                            vDSP_measqv(ptr.baseAddress! + kwOffset, 1, &ms, vDSP_Length(blockSize))
                        }
                        sumMS += Double(ms)
                    }
                    blocks.append(-0.691 + 10.0 * log10(max(sumMS, 1e-10)))
                    kwOffset += hopSize
                }

                // Trim consumed samples to keep memory bounded
                if kwOffset > blockSize {
                    for ch in 0..<nch {
                        kwBuf[ch].removeSubrange(0..<kwOffset)
                    }
                    kwOffset = 0
                }

                progressHandler(progressStart + (progressEnd - progressStart) * 0.7 * Double(readFrames) / Double(trimLength))
            }

            guard !blocks.isEmpty else { logHandler("⚠️ EBU R128: no blocks — \(readFrames) samples read (file too short?)"); return nil }
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
        // -1 dBFS ceiling — leave a little headroom for MP3 encoder intersample peaks
        let peakCeiling: Float = Float(pow(10.0, -1.0 / 20.0))  // ≈ 0.891
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
            let fmt = file.processingFormat
            let sr = fmt.sampleRate
            let inFrame  = AVAudioFramePosition(options.trimInSeconds * sr)
            let outFrame = min(options.trimOutSeconds > 0
                ? AVAudioFramePosition(options.trimOutSeconds * sr)
                : file.length, file.length)
            let trimLength = AVAudioFrameCount(max(0, outFrame - inFrame))
            let chunkSize: AVAudioFrameCount = 4096
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkSize) else { return false }

            // Pass 1: find true peak of the region
            var truePeak: Float = 0
            file.framePosition = inFrame
            var scanned: AVAudioFrameCount = 0
            while scanned < trimLength {
                let toRead = min(chunkSize, trimLength - scanned)
                buf.frameLength = toRead
                try file.read(into: buf, frameCount: toRead)
                guard buf.frameLength > 0 else { break }
                for ch in 0..<Int(fmt.channelCount) {
                    guard let data = buf.floatChannelData?[ch] else { continue }
                    var chPeak: Float = 0
                    vDSP_maxmgv(data, 1, &chPeak, vDSP_Length(buf.frameLength))
                    truePeak = max(truePeak, chPeak)
                }
                scanned += buf.frameLength
            }

            // Apply the full target gain. If peaks exceed the ceiling after boosting,
            // hard-clip them in the write loop below. For speech, sharp transient
            // clipping is largely inaudible and far preferable to leaving the file
            // 10+ dB below the loudness target.
            var gain = Float(pow(10.0, gainDB / 20.0))
            if truePeak > 0 && truePeak * gain > peakCeiling {
                let projectedDBFS = 20.0 * log10(Double(truePeak * gain))
                logHandler(String(format: "⚠️ High crest factor: peaks would reach %.1f dBFS — soft limiting to %.1f dBFS (add more compression to avoid this)",
                                  projectedDBFS, 20.0 * log10(Double(peakCeiling))))
            }

            // Pass 2: apply gain + soft limiter, then write output.
            // Instead of hard-clipping, we use a per-sample gain envelope follower:
            // fast attack (1 ms) engages the moment a peak exceeds the ceiling;
            // slow release (150 ms) lets the gain recover smoothly, avoiding pumping.
            var outSettings = fmt.settings
            outSettings.removeValue(forKey: AVChannelLayoutKey)
            if monoOutput { outSettings[AVNumberOfChannelsKey] = 1 }
            let outFile = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath), settings: outSettings)
            let outFmt = monoOutput ? AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)! : fmt
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunkSize) else { return false }

            // Limiter state — persists across chunks
            var limGain: Float = 1.0
            let attackCoeff  = Float(exp(-1.0 / (0.001 * sr)))   // 1 ms attack
            let releaseCoeff = Float(exp(-1.0 / (0.150 * sr)))   // 150 ms release
            var limGainBuf   = [Float](repeating: 1.0, count: Int(chunkSize))

            file.framePosition = inFrame
            var totalFrames: AVAudioFrameCount = 0
            while totalFrames < trimLength {
                let toRead = min(chunkSize, trimLength - totalFrames)
                buf.frameLength = toRead
                try file.read(into: buf, frameCount: toRead)
                guard buf.frameLength > 0 else { break }
                let nch = Int(fmt.channelCount)
                let n   = Int(buf.frameLength)

                // Apply target gain to all channels
                for ch in 0..<nch {
                    guard let data = buf.floatChannelData?[ch] else { continue }
                    vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(n))
                }

                // Build per-sample limiter gain from the multi-channel peak envelope
                for i in 0..<n {
                    var peak: Float = 0
                    for ch in 0..<nch {
                        if let d = buf.floatChannelData?[ch] { peak = max(peak, abs(d[i])) }
                    }
                    let tg = peak > peakCeiling ? peakCeiling / peak : 1.0
                    limGain = tg < limGain
                        ? attackCoeff  * limGain + (1 - attackCoeff)  * tg
                        : releaseCoeff * limGain + (1 - releaseCoeff) * tg
                    limGainBuf[i] = limGain
                }

                // Apply limiter envelope to all channels
                for ch in 0..<nch {
                    guard let data = buf.floatChannelData?[ch] else { continue }
                    vDSP_vmul(data, 1, limGainBuf, 1, data, 1, vDSP_Length(n))
                }
                if monoOutput && fmt.channelCount > 1 {
                    outBuf.frameLength = buf.frameLength
                    convertToMono(src: buf, dst: outBuf)
                    try outFile.write(from: outBuf)
                } else {
                    try outFile.write(from: buf)
                }
                totalFrames += buf.frameLength
                // Progress spans the second half of the allocated range (first half was peak scan)
                progressHandler(progressStart + (progressEnd - progressStart) * (0.5 + 0.5 * Double(totalFrames) / Double(trimLength)))
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
        let n = vDSP_Length(src.frameLength)
        guard Int(src.format.channelCount) > 1,
              let s = src.floatChannelData, let d = dst.floatChannelData else { return }
        // Average L+R instead of discarding a channel
        vDSP_vadd(s[0], 1, s[1], 1, d[0], 1, n)
        var divisor: Float = 2.0
        vDSP_vsdiv(d[0], 1, &divisor, d[0], 1, n)
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
