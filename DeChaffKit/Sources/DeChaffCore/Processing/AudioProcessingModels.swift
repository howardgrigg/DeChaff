import Foundation

public enum OutputFormat: String, CaseIterable, Sendable {
    case wav = "WAV"
    case mp3 = "MP3"
    public var fileExtension: String { rawValue.lowercased() }
}

public struct Chapter: Identifiable, Sendable {
    public let id: UUID
    public var timeSeconds: Double
    public var title: String

    public init(id: UUID = UUID(), timeSeconds: Double, title: String) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.title = title
    }
}

public struct ID3Metadata: Sendable {
    public var title:   String = ""
    public var artist:  String = ""
    public var album:   String = ""
    public var year:    String = ""
    public var artwork: Data?  = nil

    public init(title: String = "", artist: String = "", album: String = "",
                year: String = "", artwork: Data? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.artwork = artwork
    }
}

public struct ProcessingOptions: Sendable {
    public var voiceIsolation: Bool = true
    public var compression: Bool = true
    public var normalization: Bool = true
    public var monoOutput: Bool = false
    public var targetLUFS: Double = -16.0
    public var outputFormat: OutputFormat = .wav
    public var mp3Bitrate: Int = 64  // kbps CBR (64 / 96 / 128 / 192 / 256)
    public var shortenSilences: Bool = false
    public var maxSilenceDuration: Double = 1.0  // seconds to retain at the tail of each silent span
    public var slowLeveler: Bool = true           // windowed RMS gain envelope
    public var trimInSeconds: Double = 0
    public var trimOutSeconds: Double = 0  // 0 = use full file duration
    /// Spans cut out of the middle of the recording, in source seconds.
    /// Removed by the same pass that materialises the trim, so every later pass
    /// sees an already-cut timeline. Empty = nothing excluded.
    public var excludedRanges: [ExcludedRange] = []
    public var skipIsolationOnMusic: Bool = false  // only meaningful when voiceIsolation == true

    // Compressor parameters (used when compression == true)
    public var compressorThreshold: Float = -28.0  // dB — engagement point; lower = more compression
    public var compressorHeadRoom: Float  =   6.0  // dB — output ceiling = threshold + headRoom (before makeup)
    public var compressorAttack: Float    = 0.003  // seconds — how quickly gain engages on a rising peak
    public var compressorRelease: Float   = 0.150  // seconds — how quickly gain recovers after peak
    public var compressorMakeupGain: Float =  8.0  // dB — post-compression level boost

    public init(
        voiceIsolation: Bool = true,
        compression: Bool = true,
        normalization: Bool = true,
        monoOutput: Bool = false,
        targetLUFS: Double = -16.0,
        outputFormat: OutputFormat = .wav,
        mp3Bitrate: Int = 64,
        shortenSilences: Bool = false,
        maxSilenceDuration: Double = 1.0,
        slowLeveler: Bool = true,
        trimInSeconds: Double = 0,
        trimOutSeconds: Double = 0,
        excludedRanges: [ExcludedRange] = [],
        skipIsolationOnMusic: Bool = false,
        compressorThreshold: Float = -28.0,
        compressorHeadRoom: Float = 6.0,
        compressorAttack: Float = 0.003,
        compressorRelease: Float = 0.150,
        compressorMakeupGain: Float = 8.0
    ) {
        self.voiceIsolation = voiceIsolation
        self.compression = compression
        self.normalization = normalization
        self.monoOutput = monoOutput
        self.targetLUFS = targetLUFS
        self.outputFormat = outputFormat
        self.mp3Bitrate = mp3Bitrate
        self.shortenSilences = shortenSilences
        self.maxSilenceDuration = maxSilenceDuration
        self.slowLeveler = slowLeveler
        self.trimInSeconds = trimInSeconds
        self.trimOutSeconds = trimOutSeconds
        self.excludedRanges = excludedRanges
        self.skipIsolationOnMusic = skipIsolationOnMusic
        self.compressorThreshold = compressorThreshold
        self.compressorHeadRoom = compressorHeadRoom
        self.compressorAttack = compressorAttack
        self.compressorRelease = compressorRelease
        self.compressorMakeupGain = compressorMakeupGain
    }
}

public struct SilenceSegment: Sendable {
    public let startSeconds: Double
    public let endSeconds:   Double
    public let keptSeconds:  Double  // portion retained at tail of the silent span

    public init(startSeconds: Double, endSeconds: Double, keptSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.keptSeconds = keptSeconds
    }
}

public struct MusicSegment: Sendable {
    public let startSeconds: Double   // relative to the trimmed (kept) timeline
    public let endSeconds:   Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Remaps a chapter timestamp from the original audio timeline to the shortened output timeline.
/// Chapters falling inside a removed silent region snap to the end of the kept tail.
public func remapChapterTime(_ timeSeconds: Double, using segments: [SilenceSegment]) -> Double {
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
