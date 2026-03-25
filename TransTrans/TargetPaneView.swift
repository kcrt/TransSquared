import SwiftUI

struct TargetPaneView: View {
    @Bindable var viewModel: SessionViewModel

    var body: some View {
        TranscriptPaneView(lines: viewModel.targetLines, fontSize: viewModel.fontSize)
    }
}
