import SwiftUI

extension ContentView {

    // MARK: - Step 2: Trim

    var step2View: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader(
                title: "Trim your recording",
                subtitle: "Drag the orange handles to set the start and end. Scroll to zoom in."
            )

            waveformBlock(showChapters: false)
                .padding(.horizontal, 24)

            playbackControls(showSetInOut: true)
                .padding(.horizontal, 24)
                .padding(.top, 10)

            Spacer()
        }
    }
}
