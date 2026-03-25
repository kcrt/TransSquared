import SwiftUI

struct SourcePaneView: View {
    @Bindable var viewModel: SessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Transcription text
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(viewModel.sourceLines) { line in
                                Text(line.text)
                                    .font(.system(size: viewModel.fontSize))
                                    .foregroundStyle(line.isPartial ? .secondary : .primary)
                                    .italic(line.isPartial)
                                    .id(line.id)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(8)
                        .frame(width: geometry.size.width, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: viewModel.sourceLines.count) {
                        if let lastLine = viewModel.sourceLines.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastLine.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}
