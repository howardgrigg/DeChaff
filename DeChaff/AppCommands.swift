import SwiftUI

// MARK: - Focused values for connecting commands to ContentView state

struct FocusedModelKey: FocusedValueKey {
    typealias Value = ProcessingModel
}

struct FocusedStepKey: FocusedValueKey {
    typealias Value = Binding<Int>
}

struct FocusedActionsKey: FocusedValueKey {
    typealias Value = AppActions
}

struct FocusedUndoManagerKey: FocusedValueKey {
    typealias Value = UndoManager
}

extension FocusedValues {
    var processingModel: ProcessingModel? {
        get { self[FocusedModelKey.self] }
        set { self[FocusedModelKey.self] = newValue }
    }
    var currentStep: Binding<Int>? {
        get { self[FocusedStepKey.self] }
        set { self[FocusedStepKey.self] = newValue }
    }
    var appActions: AppActions? {
        get { self[FocusedActionsKey.self] }
        set { self[FocusedActionsKey.self] = newValue }
    }
    var windowUndoManager: UndoManager? {
        get { self[FocusedUndoManagerKey.self] }
        set { self[FocusedUndoManagerKey.self] = newValue }
    }
}

/// Bundles callbacks that commands can invoke on ContentView.
struct AppActions {
    var openFile: () -> Void
    var addChapter: () -> Void
    var startProcessing: () -> Void
}

// MARK: - Menu commands

struct DechaffCommands: Commands {
    @FocusedValue(\.processingModel) var model
    @FocusedValue(\.currentStep) var step
    @FocusedValue(\.appActions) var actions
    @FocusedValue(\.windowUndoManager) var windowUndoManager

    var body: some Commands {
        // Replace File > New with Open
        CommandGroup(replacing: .newItem) {
            Button("Open Audio File…") {
                actions?.openFile()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // Playback menu (JKL shuttle control)
        CommandMenu("Playback") {
            Button("Play / Pause") {
                model?.togglePlayback()
            }
            .keyboardShortcut("k", modifiers: [])
            .disabled(model?.inputURL == nil || !isPlaybackStep)

            Divider()

            Button("Scrub Back 5s") {
                guard let m = model else { return }
                m.seekPlayback(to: max(0, m.playback.playheadSeconds - 5))
            }
            .keyboardShortcut("j", modifiers: [])
            .disabled(model?.inputURL == nil || !isPlaybackStep)

            Button("Scrub Forward 5s") {
                guard let m = model else { return }
                m.seekPlayback(to: min(m.inputDuration, m.playback.playheadSeconds + 5))
            }
            .keyboardShortcut("l", modifiers: [])
            .disabled(model?.inputURL == nil || !isPlaybackStep)

            Divider()

            Button("Scrub Back 5s ←") {
                guard let m = model else { return }
                m.seekPlayback(to: max(0, m.playback.playheadSeconds - 5))
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(model?.inputURL == nil || !isPlaybackStep)

            Button("Scrub Forward 5s →") {
                guard let m = model else { return }
                m.seekPlayback(to: min(m.inputDuration, m.playback.playheadSeconds + 5))
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(model?.inputURL == nil || !isPlaybackStep)
        }

        // Markers menu
        CommandMenu("Markers") {
            Button("Set Trim In") {
                guard let m = model else { return }
                let oldIn = m.trimInSeconds, oldOut = m.trimOutSeconds
                m.trimInSeconds = min(m.playback.playheadSeconds, m.trimOutSeconds - 0.5)
                registerTrimUndo(model: m, oldIn: oldIn, oldOut: oldOut)
            }
            .keyboardShortcut("i", modifiers: [])
            .disabled(model?.inputURL == nil || step?.wrappedValue != 1)

            Button("Set Trim Out") {
                guard let m = model else { return }
                let oldIn = m.trimInSeconds, oldOut = m.trimOutSeconds
                m.trimOutSeconds = max(m.playback.playheadSeconds, m.trimInSeconds + 0.5)
                registerTrimUndo(model: m, oldIn: oldIn, oldOut: oldOut)
            }
            .keyboardShortcut("o", modifiers: [])
            .disabled(model?.inputURL == nil || step?.wrappedValue != 1)

            Divider()

            Button("Add Chapter Marker") {
                actions?.addChapter()
            }
            .keyboardShortcut("m", modifiers: [])
            .disabled(model?.inputURL == nil || step?.wrappedValue != 3)
        }

        // Navigate menu
        CommandMenu("Navigate") {
            Button("Load") { step?.wrappedValue = 0 }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(model?.isProcessing == true || model?.isDone == true)
            Button("Trim") { step?.wrappedValue = 1 }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(model?.isProcessing == true || model?.isDone == true)
            Button("Info") { step?.wrappedValue = 2 }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(model?.isProcessing == true || model?.isDone == true)
            Button("Chapters") { step?.wrappedValue = 3 }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(model?.isProcessing == true || model?.isDone == true)
            Button("Output") { step?.wrappedValue = 4 }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(model?.isProcessing == true || model?.isDone == true)
        }

        // Processing
        CommandGroup(after: .newItem) {
            Divider()
            Button("Process") {
                actions?.startProcessing()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model?.inputURL == nil || model?.isProcessing == true)
        }
    }

    private var isPlaybackStep: Bool {
        guard let s = step?.wrappedValue else { return false }
        return s == 1 || s == 3
    }

    private func registerTrimUndo(model m: ProcessingModel, oldIn: Double, oldOut: Double) {
        guard let um = windowUndoManager else { return }
        let newIn = m.trimInSeconds, newOut = m.trimOutSeconds
        um.registerUndo(withTarget: m) { m in
            m.trimInSeconds = oldIn; m.trimOutSeconds = oldOut
            um.registerUndo(withTarget: m) { m in
                m.trimInSeconds = newIn; m.trimOutSeconds = newOut
            }
            um.setActionName("Trim")
        }
        um.setActionName("Trim")
    }
}
