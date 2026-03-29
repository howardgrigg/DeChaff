import Foundation

extension VoiceIsolationProcessor {

    // MARK: - MP3 encoding via bundled LAME

    func encodeToMP3(inputWAV: String, outputMP3: String, bitrate: Int, mono: Bool,
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
}
