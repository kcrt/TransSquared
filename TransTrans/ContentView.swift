import SwiftUI
import Translation

struct ContentView: View {
    @State private var viewModel = SessionViewModel()

    var body: some View {
        HStack(spacing: 0) {
            // Main content: top-bottom split
            VStack(spacing: 0) {
                TranscriptPaneView(lines: viewModel.sourceLines, fontSize: viewModel.fontSize)
                Divider()
                TranscriptPaneView(lines: viewModel.targetLines, fontSize: viewModel.fontSize)
            }

            Divider()

            // Right control strip
            ControlStripView(viewModel: viewModel)
        }
        .background(VisualEffectBackground(material: .hudWindow))
        .frame(minWidth: 320, minHeight: 200)
        .translationTask(viewModel.translationConfig) { session in
            await viewModel.handleTranslationSession(session)
        }
        .task {
            await viewModel.loadSupportedLocales()
        }
        .onAppear {
            setWindowLevel(viewModel.isAlwaysOnTop)
        }
        .onChange(of: viewModel.isAlwaysOnTop) {
            setWindowLevel(viewModel.isAlwaysOnTop)
        }
        .contextMenu {
            contextMenuItems
        }
        .focusable()
        .focusEffectDisabled()
        // Overlay invisible buttons for keyboard shortcuts
        .background {
            shortcutButtons
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .alert("Error", isPresented: showErrorBinding) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        VStack {
            Button("Start/Stop") { viewModel.toggleSession() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Swap") { viewModel.swapLanguages() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Font+") { viewModel.increaseFontSize() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Font-") { viewModel.decreaseFontSize() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Pin") { viewModel.isAlwaysOnTop.toggle() }
                .keyboardShortcut("t", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Copy All (Original)") {
            copyToClipboard(viewModel.copyAllOriginal())
        }
        Button("Copy All (Translation)") {
            copyToClipboard(viewModel.copyAllTranslation())
        }
        Button("Copy All (Interleaved)") {
            copyToClipboard(viewModel.copyAllInterleaved())
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func setWindowLevel(_ alwaysOnTop: Bool) {
        guard let window = NSApplication.shared.windows.first else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }
}

#Preview {
    ContentView()
}
