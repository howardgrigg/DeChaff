import Foundation

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
