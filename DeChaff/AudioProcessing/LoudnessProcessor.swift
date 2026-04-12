import AVFoundation
import Accelerate

// BiquadCascade is used only within loudness processing, so kept private to this file.
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

extension VoiceIsolationProcessor {

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
    func applySlowLeveler(inputPath: String, outputPath: String,
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
            // –40 dBFS gate: excludes room noise / breath noise after voice isolation,
            // which typically sits at –40 to –45 dBFS. Only windows with meaningful
            // speech content drive the gain map.
            let noiseFloor: Float = Float(pow(10.0, -40.0 / 20.0))
            let maxLinear  = Float(pow(10.0, Double(maxGainDB) / 20.0))
            let minLinear  = 1.0 / maxLinear

            // Reference: median RMS of voiced windows
            let voiced = windowRMS.filter { $0 > noiseFloor }
            guard !voiced.isEmpty else {
                logHandler("⚠️ Slow leveler: signal below noise floor, skipping")
                try FileManager.default.copyItem(atPath: inputPath, toPath: outputPath)
                return true
            }
            let reference = voiced.sorted()[voiced.count / 2]

            // Compute target gain for voiced windows; leave silent windows as -1 sentinel.
            var gainMap = [Float](repeating: -1.0, count: nWindows)
            for w in 0..<nWindows where windowRMS[w] > noiseFloor {
                gainMap[w] = max(minLinear, min(maxLinear, reference / max(windowRMS[w], 1e-10)))
            }

            // Fill silent windows by holding the nearest voiced gain rather than
            // snapping back to unity — this prevents the gain envelope from drifting
            // down through quiet gaps (the "pumping" artefact).
            // Forward pass: propagate last voiced gain into following silence.
            var hold: Float = 1.0
            for i in 0..<nWindows {
                if gainMap[i] >= 0 { hold = gainMap[i] } else { gainMap[i] = hold }
            }
            // Backward pass: fill any leading silence before the first voiced window.
            hold = 1.0
            for i in stride(from: nWindows - 1, through: 0, by: -1) {
                if windowRMS[i] > noiseFloor { hold = gainMap[i] } else if gainMap[i] == 1.0 { gainMap[i] = hold }
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

    func measureLUFS(path: String, options: ProcessingOptions,
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

    func applyGain(inputPath: String, outputPath: String, gainDB: Double, targetLUFS: Double,
                   monoOutput: Bool, options: ProcessingOptions,
                   progressStart: Double, progressEnd: Double) -> Bool {
        // -1 dBFS ceiling — leave headroom for MP3 encoder intersample peaks
        let peakCeiling: Float = Float(pow(10.0, -1.0 / 20.0))  // ≈ 0.891
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
            let fmt = file.processingFormat
            let sr = fmt.sampleRate
            let nch = Int(fmt.channelCount)
            let inFrame  = AVAudioFramePosition(options.trimInSeconds * sr)
            let outFrame = min(options.trimOutSeconds > 0
                ? AVAudioFramePosition(options.trimOutSeconds * sr)
                : file.length, file.length)
            let trimLength = AVAudioFrameCount(max(0, outFrame - inFrame))
            let chunkSize: AVAudioFrameCount = 4096
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkSize) else { return false }

            var gain = Float(pow(10.0, gainDB / 20.0))

            // Pass 2: apply gain + look-ahead limiter, then write output.
            //
            // A retrospective (feedback) limiter cannot prevent the first few samples of a
            // transient from clipping because it hasn't engaged yet. A look-ahead limiter
            // solves this by delaying the audio signal by L samples while the gain computer
            // inspects the undelayed (future) signal. By the time a peak arrives in the
            // output, the gain has already been ramped down to handle it — zero clipping.
            //
            // Implementation: circular ring buffer per channel, L = 3 ms (≈ 132 samples
            // at 44.1 kHz). For each sample, the limiter reads the undelayed (future)
            // peak, updates the gain envelope, then outputs the delayed sample scaled by
            // that gain. At end-of-file the ring buffer is flushed with silence as
            // look-ahead so the remaining L frames are written cleanly.
            var outSettings = fmt.settings
            outSettings.removeValue(forKey: AVChannelLayoutKey)
            if monoOutput { outSettings[AVNumberOfChannelsKey] = 1 }
            let outFile = try AVAudioFile(forWriting: URL(fileURLWithPath: outputPath), settings: outSettings)
            let outFmt = monoOutput ? AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)! : fmt
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunkSize) else { return false }

            // Look-ahead ring buffer — one float array per channel, length L
            let lookAheadSamples = max(1, Int(0.003 * sr))   // 3 ms
            var ringBuf = Array(repeating: [Float](repeating: 0.0, count: lookAheadSamples), count: nch)
            var ringPos = 0

            // Limiter state — persists across chunks
            var limGain: Float = 1.0
            let attackCoeff  = Float(exp(-1.0 / (0.001 * sr)))   // 1 ms attack
            let releaseCoeff = Float(exp(-1.0 / (0.150 * sr)))   // 150 ms release

            // Helper: process one sample through the look-ahead limiter.
            // `futureChannels` are the undelayed (gain-applied) channel pointers at index i.
            // Returns the limiter-scaled delayed sample for each channel via `buf`.
            func processOneSample(i: Int) {
                // 1. Compute the peak of the undelayed (future) sample across all channels
                var peak: Float = 0
                for ch in 0..<nch {
                    if let d = buf.floatChannelData?[ch] { peak = max(peak, abs(d[i])) }
                }
                // 2. Update limiter gain from future peak (attack/release envelope follower)
                let tg: Float = peak > peakCeiling ? peakCeiling / peak : 1.0
                limGain = tg < limGain
                    ? attackCoeff  * limGain + (1 - attackCoeff)  * tg
                    : releaseCoeff * limGain + (1 - releaseCoeff) * tg
                // 3. Swap: read delayed sample, write future sample into ring, output delayed*gain
                for ch in 0..<nch {
                    if let d = buf.floatChannelData?[ch] {
                        let future = d[i]
                        d[i] = ringBuf[ch][ringPos] * limGain   // output = delayed * current gain
                        ringBuf[ch][ringPos] = future            // store future for later
                    }
                }
                ringPos = (ringPos + 1) % lookAheadSamples
            }

            file.framePosition = inFrame
            var totalFrames: AVAudioFrameCount = 0
            while totalFrames < trimLength {
                let toRead = min(chunkSize, trimLength - totalFrames)
                buf.frameLength = toRead
                try file.read(into: buf, frameCount: toRead)
                guard buf.frameLength > 0 else { break }
                let n = Int(buf.frameLength)

                // Apply normalization gain to all channels
                for ch in 0..<nch {
                    guard let data = buf.floatChannelData?[ch] else { continue }
                    vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(n))
                }

                // Run look-ahead limiter sample-by-sample (overwrites buf in place)
                for i in 0..<n { processOneSample(i: i) }

                if monoOutput && fmt.channelCount > 1 {
                    outBuf.frameLength = buf.frameLength
                    convertToMono(src: buf, dst: outBuf)
                    try outFile.write(from: outBuf)
                } else {
                    try outFile.write(from: buf)
                }
                totalFrames += buf.frameLength
                // Progress spans the second half of the allocated range (first half is reserved
                // for a peak-scan pass we no longer need, kept for progress consistency)
                progressHandler(progressStart + (progressEnd - progressStart) * (0.5 + 0.5 * Double(totalFrames) / Double(trimLength)))
            }

            // Flush: drain the remaining `lookAheadSamples` frames from the ring buffer.
            // Feed silence as future input so the limiter releases smoothly.
            let flushCap = AVAudioFrameCount(lookAheadSamples)
            guard let flushBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: flushCap) else { return false }
            flushBuf.frameLength = flushCap
            // Zero the buffer (silence = no future peaks → limiter releases)
            for ch in 0..<nch {
                if let d = flushBuf.floatChannelData?[ch] {
                    vDSP_vclr(d, 1, vDSP_Length(lookAheadSamples))
                }
            }
            // Process flush frames directly (inline rather than via processOneSample,
            // since future input is known to be silence — no need to read buf).
            for i in 0..<lookAheadSamples {
                // Future peak = 0 (silence), so tg = 1.0 → limiter releases
                limGain = releaseCoeff * limGain + (1 - releaseCoeff) * 1.0
                for ch in 0..<nch {
                    if let d = flushBuf.floatChannelData?[ch] {
                        d[i] = ringBuf[ch][ringPos] * limGain
                    }
                }
                ringPos = (ringPos + 1) % lookAheadSamples
            }
            if monoOutput && fmt.channelCount > 1 {
                guard let monoFlush = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: flushCap) else { return false }
                monoFlush.frameLength = flushCap
                convertToMono(src: flushBuf, dst: monoFlush)
                try outFile.write(from: monoFlush)
            } else {
                try outFile.write(from: flushBuf)
            }

            logHandler(String(format: "✅ Normalized to %.1f LUFS", targetLUFS))
            return true
        } catch {
            logHandler("❌ Gain pass failed: \(error.localizedDescription)"); return false
        }
    }
}
