import AVFoundation
import AudioToolbox
import Accelerate

extension VoiceIsolationProcessor {

    // MARK: - File loading

    func loadAudioFile(path: String) -> AVAudioFile? {
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

    func runAUPass(audioFile: AVAudioFile, outputPath: String,
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
            AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold,     kAudioUnitScope_Global, 0, options.compressorThreshold, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom,      kAudioUnitScope_Global, 0, options.compressorHeadRoom,  0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime,    kAudioUnitScope_Global, 0, options.compressorAttack,    0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime,   kAudioUnitScope_Global, 0, options.compressorRelease,   0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain,   kAudioUnitScope_Global, 0, options.compressorMakeupGain,0)
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

    func renderAU(_ au: AudioUnit, from input: AVAudioPCMBuffer,
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

    // MARK: - Helpers

    func convertToMono(src: AVAudioPCMBuffer, dst: AVAudioPCMBuffer) {
        let n = vDSP_Length(src.frameLength)
        guard Int(src.format.channelCount) > 1,
              let s = src.floatChannelData, let d = dst.floatChannelData else { return }
        // Average L+R instead of discarding a channel
        vDSP_vadd(s[0], 1, s[1], 1, d[0], 1, n)
        var divisor: Float = 2.0
        vDSP_vsdiv(d[0], 1, &divisor, d[0], 1, n)
        dst.frameLength = src.frameLength
    }
}
