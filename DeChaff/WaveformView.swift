import SwiftUI
import AppKit

// MARK: - WaveformView (viewport-rendered waveform with pan + zoom)

struct WaveformView: View {
    let waveformData: WaveformData
    let duration: Double
    @Binding var trimIn: Double
    @Binding var trimOut: Double
    let playhead: Double
    let chapters: [Chapter]
    let trimInOffset: Double
    var onSeek: (Double) -> Void
    var onChapterMove: ((UUID, Double) -> Void)?
    var onTrimDragEnd: ((_ oldIn: Double, _ oldOut: Double) -> Void)?
    var onChapterDragEnd: ((_ id: UUID, _ oldTime: Double) -> Void)?
    @Binding var zoom: Double
    @Binding var visibleStart: Double
    var onViewWidth: ((CGFloat) -> Void)?
    var onCursorFraction: ((Double) -> Void)?
    let tileCache: WaveformTileCache
    var transcriptWords: [TranscriptWord] = []

    @State private var dragHandle: Int? = nil   // 0=trimIn 1=trimOut -1=tap -2=chapter -3=pan
    @State private var dragChapterID: UUID? = nil
    @State private var dragStartTrimIn: Double = 0
    @State private var dragStartTrimOut: Double = 0
    @State private var dragStartChapterTime: Double = 0
    @State private var dragStartVisibleStart: Double = 0
    @State private var lastMagnification: Double = 1.0
    @State private var viewportWidth: CGFloat = 700

    private var visibleDuration: Double { duration / zoom }
    private var fullWidth: CGFloat { viewportWidth * CGFloat(zoom) }

    private func clampStart(_ s: Double) -> Double { max(0, min(s, duration - visibleDuration)) }

    /// Map a time value to an x-coordinate in viewport space.
    private func viewportX(_ t: Double) -> CGFloat {
        CGFloat((t - visibleStart) / visibleDuration) * viewportWidth
    }

    /// Map an x-coordinate in viewport space to a time value.
    private func timeAt(_ x: CGFloat) -> Double {
        max(0, min(duration, visibleStart + Double(x / viewportWidth) * visibleDuration))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let _ = DispatchQueue.main.async { viewportWidth = w; onViewWidth?(w) }

            ZStack(alignment: .topLeading) {
                // Layer 1: Tiled waveform — only renders the visible slice
                WaveformTiledContent(
                    waveformData: waveformData,
                    duration: duration,
                    trimIn: trimIn,
                    trimOut: trimOut,
                    tileCache: tileCache,
                    viewportWidth: w,
                    visibleStart: visibleStart,
                    visibleDuration: visibleDuration,
                    height: h,
                    zoom: zoom
                )

                // Layer 2: Overlay — dim regions, handles, chapters, playhead in viewport coords
                Canvas { ctx, size in
                    let vw = size.width
                    let fh = size.height
                    guard duration > 0 else { return }

                    // Transcript words at top of waveform (drawn first, under other overlays)
                    if !transcriptWords.isEmpty {
                        let wordFont = Font.system(size: 11)
                        var nextX: CGFloat = 0
                        let yPos: CGFloat = 11

                        for word in transcriptWords {
                            guard word.endTime >= visibleStart else { continue }
                            guard word.startTime <= visibleStart + visibleDuration else { break }

                            let x = max(0, viewportX(word.startTime))
                            if x < nextX {
                                // Skipped word — dot at its actual time position, vertically centred with text
                                if x < vw {
                                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: yPos - 1.5, width: 3, height: 3)),
                                             with: .color(Color.primary.opacity(0.25)))
                                }
                                continue
                            }

                            let resolved = ctx.resolve(
                                Text(word.text)
                                    .font(wordFont)
                                    .foregroundStyle(Color.primary.opacity(0.8))
                            )
                            let wordSize = resolved.measure(in: CGSize(width: vw, height: 16))
                            guard x + wordSize.width <= vw + 4 else { break }

                            // Background pill for legibility
                            ctx.fill(
                                Path(roundedRect: CGRect(x: x - 1, y: yPos - wordSize.height + 2, width: wordSize.width + 2, height: wordSize.height), cornerRadius: 2),
                                with: .color(Color(NSColor.windowBackgroundColor).opacity(0.6))
                            )
                            ctx.draw(resolved, at: CGPoint(x: x, y: yPos), anchor: .leading)
                            nextX = x + wordSize.width + 4
                        }
                    }

                    // Dim outside trim
                    let trimInX  = viewportX(trimIn)
                    let trimOutX = viewportX(trimOut)
                    let dimColor = Color.black.opacity(0.35)
                    if trimInX > 0 {
                        ctx.fill(Path(CGRect(x: 0, y: 0, width: min(trimInX, vw), height: fh)), with: .color(dimColor))
                    }
                    if trimOutX < vw {
                        ctx.fill(Path(CGRect(x: max(0, trimOutX), y: 0, width: vw - max(0, trimOutX), height: fh)), with: .color(dimColor))
                    }

                    // Chapter markers
                    var lastLabelX: CGFloat = -100
                    for chapter in chapters.sorted(by: { $0.timeSeconds < $1.timeSeconds }) {
                        let inputTime = chapter.timeSeconds + trimInOffset
                        let x = viewportX(inputTime)
                        guard x >= 0 && x <= vw else { continue }
                        let isDragging = chapter.id == dragChapterID
                        let chapterColor = Color.accentColor
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: fh)) },
                                   with: .color(isDragging ? Color.yellow : chapterColor.opacity(0.8)),
                                   lineWidth: isDragging ? 2 : 1.5)
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: fh * 0.5 - 4, width: 8, height: 8)),
                                 with: .color(isDragging ? Color.yellow : chapterColor.opacity(0.7)))
                        if x - lastLabelX >= 30 {
                            let label = chapter.title.isEmpty ? "●" : String(chapter.title.prefix(12))
                            ctx.draw(Text(label).font(.system(size: 9, weight: isDragging ? .bold : .regular))
                                        .foregroundStyle(isDragging ? Color.yellow : chapterColor),
                                     at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                            lastLabelX = x
                        }
                    }

                    // Trim handles
                    func drawHandle(x: CGFloat) {
                        guard x >= -9 && x <= vw + 9 else { return }
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: fh)) },
                                   with: .color(.white.opacity(0.35)), lineWidth: 6)
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: fh)) },
                                   with: .color(.orange), lineWidth: 2)
                        ctx.fill(Path { p in
                            p.move(to: CGPoint(x: x - 9, y: 0)); p.addLine(to: CGPoint(x: x + 9, y: 0))
                            p.addLine(to: CGPoint(x: x, y: 14)); p.closeSubpath()
                        }, with: .color(.orange))
                        ctx.fill(Path { p in
                            p.move(to: CGPoint(x: x - 9, y: fh)); p.addLine(to: CGPoint(x: x + 9, y: fh))
                            p.addLine(to: CGPoint(x: x, y: fh - 14)); p.closeSubpath()
                        }, with: .color(.orange))
                    }
                    drawHandle(x: trimInX)
                    drawHandle(x: trimOutX)

                    // Playhead
                    let phX = viewportX(playhead)
                    if phX >= 0 && phX <= vw {
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: phX, y: 0)); p.addLine(to: CGPoint(x: phX, y: fh)) },
                                   with: .color(Color(red: 1.0, green: 0.78, blue: 0.0)), lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)

                // Layer 3: Gesture capture
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                let startX = value.startLocation.x
                                let curX   = value.location.x
                                let dx = value.translation.width
                                let dy = value.translation.height

                                if dragHandle == nil {
                                    // Decide what was grabbed at the initial touch point
                                    let inX  = viewportX(trimIn)
                                    let outX = viewportX(trimOut)
                                    let dIn  = abs(startX - inX)
                                    let dOut = abs(startX - outX)
                                    if dIn <= 12 || dOut <= 12 {
                                        dragHandle = dIn < dOut ? 0 : 1
                                        dragStartTrimIn = trimIn
                                        dragStartTrimOut = trimOut
                                    } else {
                                        var best: (dist: CGFloat, id: UUID)? = nil
                                        for ch in chapters {
                                            let cx = viewportX(ch.timeSeconds + trimInOffset)
                                            let d  = abs(startX - cx)
                                            if d <= 10, best == nil || d < best!.dist { best = (d, ch.id) }
                                        }
                                        if let hit = best {
                                            dragHandle = -2; dragChapterID = hit.id
                                            dragStartChapterTime = chapters.first(where: { $0.id == hit.id })?.timeSeconds ?? 0
                                        } else if abs(dx) > 4 && abs(dx) >= abs(dy) && zoom > 1.0 {
                                            // Horizontal pan — only when zoomed in and clearly horizontal
                                            dragHandle = -3
                                            dragStartVisibleStart = visibleStart
                                        } else if abs(dx) > 4 || abs(dy) > 4 {
                                            dragHandle = -1  // unrecognised drag — ignore
                                        }
                                        // if movement < 4pt in any direction, leave dragHandle nil (possible tap)
                                    }
                                }

                                switch dragHandle {
                                case 0:
                                    trimIn = min(timeAt(curX), trimOut - 0.5); onSeek(trimIn)
                                case 1:
                                    trimOut = max(timeAt(curX), trimIn + 0.5); onSeek(trimOut)
                                case -2:
                                    if let id = dragChapterID {
                                        let time = timeAt(curX)
                                        onChapterMove?(id, max(0, time - trimInOffset))
                                        onSeek(time)
                                    }
                                case -3:
                                    // Pan: shift visibleStart opposite to drag direction
                                    let timeDelta = Double(-dx / viewportWidth) * visibleDuration
                                    visibleStart = clampStart(dragStartVisibleStart + timeDelta)
                                default: break
                                }
                            }
                            .onEnded { value in
                                let totalMove = abs(value.translation.width) + abs(value.translation.height)
                                if dragHandle == nil || (dragHandle == -1 && totalMove < 5) {
                                    // Tap — seek to tapped position
                                    onSeek(timeAt(value.startLocation.x))
                                }
                                if dragHandle == 0 || dragHandle == 1 {
                                    if trimIn != dragStartTrimIn || trimOut != dragStartTrimOut {
                                        onTrimDragEnd?(dragStartTrimIn, dragStartTrimOut)
                                    }
                                }
                                if dragHandle == -2, let id = dragChapterID {
                                    let currentTime = chapters.first(where: { $0.id == id })?.timeSeconds ?? 0
                                    if currentTime != dragStartChapterTime {
                                        onChapterDragEnd?(id, dragStartChapterTime)
                                    }
                                }
                                dragHandle = nil; dragChapterID = nil
                            }
                    )

                // Zoom level indicator
                if zoom > 1.01 {
                    VStack {
                        HStack {
                            Spacer()
                            Text(zoom >= 10 ? String(format: "%.0f×", zoom) : String(format: "%.1f×", zoom))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let delta = Double(value) / lastMagnification
                        lastMagnification = Double(value)
                        let centre = visibleStart + visibleDuration / 2
                        zoom = max(1.0, min(1000.0, zoom * delta))
                        visibleStart = clampStart(centre - visibleDuration / 2)
                        tileCache.invalidateAll()
                    }
                    .onEnded { _ in lastMagnification = 1.0 }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { zoom = 1.0; visibleStart = 0 }
                tileCache.invalidateAll()
            }
            .onContinuousHover { phase in
                if case .active(let loc) = phase, viewportWidth > 0 {
                    onCursorFraction?(Double(loc.x / viewportWidth))
                }
            }
            .onChange(of: playhead) { ph in
                guard zoom > 1.0 else { return }
                let vEnd = visibleStart + visibleDuration
                if ph < visibleStart || ph > vEnd {
                    visibleStart = clampStart(ph - visibleDuration * 0.1)
                }
            }
            .onChange(of: duration) { _ in zoom = 1.0; visibleStart = 0 }
        }
    }
}

// MARK: - Tiled waveform content (viewport-only rendering)

private struct WaveformTiledContent: View {
    let waveformData: WaveformData
    let duration: Double
    let trimIn: Double
    let trimOut: Double
    let tileCache: WaveformTileCache
    let viewportWidth: CGFloat
    let visibleStart: Double
    let visibleDuration: Double
    let height: CGFloat
    let zoom: Double

    var body: some View {
        Canvas { ctx, size in
            let vw = size.width
            let h = size.height
            guard duration > 0, vw > 0, visibleDuration > 0 else { return }

            let (peaks, fpp) = waveformData.peaks(forZoom: zoom, viewportWidth: viewportWidth)
            guard !peaks.isEmpty else { return }

            // Full virtual content width at this zoom level
            let fullW = viewportWidth * CGFloat(zoom)
            let tileW = tileCache.tileWidth
            let totalTiles = Int(ceil(fullW / tileW))
            let quantZoom = WaveformTileCache.quantiseZoom(zoom)
            let trimInHash = Int(trimIn * 100)
            let trimOutHash = Int(trimOut * 100)

            let accentCG = NSColor.controlAccentColor.cgColor
            let dimCG = NSColor.secondaryLabelColor.withAlphaComponent(0.4).cgColor

            // Pixel offset of the visible window within the full virtual content
            let visibleStartPx = CGFloat(visibleStart / duration) * fullW

            // Only render tiles that overlap the visible viewport
            let firstTile = max(0, Int(visibleStartPx / tileW))
            let lastTile  = min(totalTiles - 1, Int((visibleStartPx + vw) / tileW))
            guard firstTile <= lastTile else { return }

            for ti in firstTile...lastTile {
                let tileOriginPx  = CGFloat(ti) * tileW
                let tileOriginSec = Double(tileOriginPx / fullW) * duration
                let tileDurSec    = Double(tileW / fullW) * duration
                let drawX         = tileOriginPx - visibleStartPx  // x in viewport space

                let key = WaveformTileCache.TileKey(
                    zoomLevel: quantZoom, tileIndex: ti,
                    trimInHash: trimInHash, trimOutHash: trimOutHash
                )

                let image: CGImage?
                if let cached = tileCache.tile(for: key) {
                    image = cached
                } else {
                    image = tileCache.renderTile(
                        key: key, peaks: peaks, framesPerPeak: fpp,
                        sampleRate: waveformData.sampleRate, duration: duration,
                        tileOriginSeconds: tileOriginSec, tileDurationSeconds: tileDurSec,
                        trimIn: trimIn, trimOut: trimOut, height: h,
                        accentColor: accentCG, dimColor: dimCG
                    )
                }

                if let image {
                    let rect = CGRect(x: drawX, y: 0, width: tileW, height: h)
                    ctx.draw(Image(decorative: image, scale: 1), in: rect)
                }
            }
        }
    }
}
