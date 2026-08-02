import Foundation
import AudioToolbox
import AVFoundation
import Accelerate

class VoiceIsolationProcessor {
    let isolationSubType: UInt32 = 0x766f6973
    var logHandler: (String) -> Void = { _ in }
    var progressHandler: (Double) -> Void = { _ in }
    private(set) var detectedSilenceSegments: [SilenceSegment] = []

    // Cancellation — cancel() is called from the main thread while the pass
    // loops poll isCancelled from the processing queue.
    private let cancelLock = NSLock()
    private var cancelledFlag = false
    private var encoderProcess: Process?

    var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelledFlag
    }

    func cancel() {
        cancelLock.lock()
        cancelledFlag = true
        let encoder = encoderProcess
        cancelLock.unlock()
        encoder?.terminate()
    }

    /// Registers the running LAME process so cancel() can terminate it.
    func setEncoderProcess(_ process: Process?) {
        cancelLock.lock()
        encoderProcess = process
        cancelLock.unlock()
    }

    /// Static render callback — avoids a closure allocation per chunk.
    /// The refcon is updated via AudioUnitSetProperty before each render call.
    static let auRenderCallback: AURenderCallback = { inRefCon, _, _, _, _, ioData in
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

        // Music detection runs before everything else and gets its own reserved
        // slice at the front; every downstream progress value is shifted into the
        // remaining space via `scaled(_:)`, same idea as `silenceScale`'s tail slice.
        let musicDetectActive = options.voiceIsolation && options.skipIsolationOnMusic
        let musicDetectScale: Double = musicDetectActive ? 0.05 : 0.0
        func scaled(_ raw: Double) -> Double { musicDetectScale + raw * (1.0 - musicDetectScale) }

        var musicSegments: [MusicSegment] = []
        if musicDetectActive {
            musicSegments = detectMusicSegments(audioFile: audioFile, options: options,
                                                progressStart: 0.0, progressEnd: musicDetectScale) ?? []
        }

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

        // Pass 1: isolation + compression (also materializes trim + mono).
        // When the AU pass is skipped, a plain copy pass does the same, so every
        // downstream pass starts from correctly trimmed audio no matter which
        // combination of toggles is enabled.
        var normSource: String
        if needsAU {
            let p1End = (options.normalization || levelerActive) ? p_auEnd * auNormScale : auNormScale
            let ok = runAUPass(audioFile: audioFile, outputPath: auOutputPath,
                               options: options, musicSegments: musicSegments,
                               progressStart: scaled(0.0), progressEnd: scaled(p1End))
            guard ok else { temps.forEach(cleanup); return false }
            normSource = auOutputPath
        } else {
            let hasDownstream = levelerActive || options.normalization
            let copyDest = hasDownstream ? makeTempPath() : wavOutputPath
            let copyEnd  = hasDownstream ? 0.10 * auNormScale : auNormScale
            let ok = copyPass(inputPath: inputPath, outputPath: copyDest, options: options,
                              progressStart: scaled(0.0), progressEnd: scaled(copyEnd))
            guard ok else { temps.forEach(cleanup); return false }
            normSource = copyDest
        }

        // Pass 1.5: slow leveler — after AU/copy, before normalization.
        // Builds a smooth per-sample gain envelope from 1-second window RMS measurements,
        // clamped to ±6 dB, to even out sustained level differences between speakers.
        if levelerActive {
            let levelerPath = options.normalization ? makeTempPath() : wavOutputPath
            let lStart = needsAU ? p_auEnd * auNormScale : 0.10 * auNormScale
            let lEnd   = needsAU ? p_levEnd * auNormScale
                                 : (options.normalization ? 0.35 * auNormScale : auNormScale)
            let ok = applySlowLeveler(inputPath: normSource, outputPath: levelerPath,
                                      progressStart: scaled(lStart), progressEnd: scaled(lEnd))
            guard ok else { temps.forEach(cleanup); return false }
            cleanup(normSource)
            normSource = levelerPath
        }

        // Pass 2: normalization
        if options.normalization {
            let pStart = needsAU ? p_levEnd * auNormScale
                                 : (levelerActive ? 0.35 * auNormScale : 0.10 * auNormScale)
            let pMid   = needsAU ? p_measEnd * auNormScale
                                 : (levelerActive ? 0.65 * auNormScale : 0.7 * auNormScale)
            // Source audio is already trimmed and downmixed — empty options make
            // measureLUFS/applyGain read the whole file with no further conversion.
            guard let measured = measureLUFS(path: normSource, options: ProcessingOptions(),
                                             progressStart: scaled(pStart), progressEnd: scaled(pMid)) else {
                logHandler("❌ Loudness measurement failed — skipping normalization")
                temps.forEach(cleanup); return false
            }
            let gainDB = options.targetLUFS - measured
            logHandler(String(format: "Measured %.1f LUFS → target %.1f LUFS (%+.1f dB)",
                               measured, options.targetLUFS, gainDB))
            let ok = applyGain(inputPath: normSource, outputPath: wavOutputPath,
                               gainDB: gainDB, targetLUFS: options.targetLUFS,
                               monoOutput: false,
                               options: ProcessingOptions(),
                               progressStart: scaled(pMid), progressEnd: scaled(auNormScale))
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
                                                  progressStart: scaled(auNormScale),
                                                  progressEnd: scaled(auNormScale + silenceScale))
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
                    progressHandler(scaled(auNormScale + silenceScale))
                }
            } else {
                logHandler("⚠️ Silence detection failed — skipping")
                progressHandler(scaled(auNormScale + silenceScale))
            }
        } else {
            detectedSilenceSegments = []
        }

        // Pass 3: MP3 encoding
        if encodingMP3 {
            let ok = encodeToMP3(inputWAV: wavOutputPath, outputMP3: outputPath,
                                 bitrate: options.mp3Bitrate, mono: options.monoOutput,
                                 progressStart: scaled(auNormScale), progressEnd: 1.0)
            cleanup(wavOutputPath)
            return ok
        }

        return true
    }

    func cleanup(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
