import SwiftUI
import AVFoundation

// MARK: - Helpers

func formatPlaybackTime(_ seconds: Double) -> String {
    let t = max(0, seconds)
    let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - PlaybackState

/// Isolated `@Observable` for playback so that the 20 Hz timer only invalidates
/// views that read `isPlaying` or `playheadSeconds`, not the entire hierarchy.
@MainActor @Observable
final class PlaybackState {
    var isPlaying = false
    var playheadSeconds: Double = 0
    /// When set, playback auto-pauses once the playhead reaches this time (e.g. the trim-out point).
    var stopAt: Double? = nil
    /// Spans the playhead jumps over during playback — the user's excluded ranges,
    /// so auditioning the trim step plays what the listener will actually hear.
    /// Explicit seeks are never redirected; only playback advancing into a range is.
    var skipRanges: [(start: Double, end: Double)] = []

    private var audioPlayer: AVAudioPlayer?
    private var playerURL: URL?
    private var playbackTimer: Timer?

    func toggle(url: URL?) {
        isPlaying ? pause() : playFrom(playheadSeconds, url: url)
    }

    func playFrom(_ t: Double, url: URL?) {
        guard let url else { return }
        // Reuse the player on resume — re-opening a 90-minute file on every
        // spacebar press causes a visible hitch before playback starts.
        if audioPlayer == nil || playerURL != url {
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
            player.prepareToPlay()
            audioPlayer = player
            playerURL = url
        }
        guard let player = audioPlayer else { return }
        player.currentTime = t
        player.play()
        isPlaying = true
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.audioPlayer else { return }
            if let stop = self.stopAt, p.currentTime >= stop {
                p.pause()
                self.playheadSeconds = stop
                self.isPlaying = false
                self.playbackTimer?.invalidate()
                return
            }
            // Jump the excluded spans rather than play audio the output won't contain.
            if let skip = self.skipRanges.first(where: { p.currentTime >= $0.start && p.currentTime < $0.end }) {
                p.currentTime = skip.end
            }
            self.playheadSeconds = p.currentTime
            if !p.isPlaying { self.isPlaying = false; self.playbackTimer?.invalidate() }
        }
    }

    func pause() {
        audioPlayer?.pause(); isPlaying = false; playbackTimer?.invalidate()
    }

    func stop() {
        audioPlayer?.stop(); audioPlayer = nil; playerURL = nil
        isPlaying = false; playbackTimer?.invalidate(); playheadSeconds = 0
    }

    func seek(to time: Double) {
        playheadSeconds = time
        audioPlayer?.currentTime = time
    }
}
