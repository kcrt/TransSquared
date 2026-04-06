import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SessionViewModel

    private var localeDisplayName: String {
        let locale = Locale(identifier: viewModel.sourceLocaleIdentifier)
        return Locale.current.localizedString(forIdentifier: locale.identifier) ?? viewModel.sourceLocaleIdentifier
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding([.top, .horizontal])
            .padding(.bottom, 8)

            TabView {
                GeneralTab(viewModel: viewModel)
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                VocabularyTab(viewModel: viewModel, localeDisplayName: localeDisplayName)
                    .tabItem {
                        Label("Custom Vocabulary", systemImage: "text.book.closed")
                    }
                AutoReplaceTab(viewModel: viewModel, localeDisplayName: localeDisplayName)
                    .tabItem {
                        Label("Auto Replace", systemImage: "arrow.2.squarepath")
                    }
            }
        }
        .frame(width: 420, height: 440)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @Bindable var viewModel: SessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Silence Duration for Sentence Boundary")
                .font(.subheadline.bold())

            Text("Duration of silence before the current speech segment is finalized as a sentence.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("0.5s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $viewModel.sentenceBoundarySeconds, in: 0.5...5.0, step: 0.5)
                Text("5.0s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(viewModel.sentenceBoundarySeconds, specifier: "%.1f") seconds")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Custom Vocabulary Tab

private struct VocabularyTab: View {
    @Bindable var viewModel: SessionViewModel
    let localeDisplayName: String
    @State private var newWord = ""
    @FocusState private var isNewWordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add words or short phrases to improve speech recognition accuracy for specialized terminology. Vocabulary is saved per source language.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("These words are provided as hints to the speech recognition engine and may not always be prioritized.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Label(localeDisplayName, systemImage: "globe")
                .font(.subheadline.bold())

            HStack {
                TextField("New word or phrase", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNewWordFocused)
                    .onSubmit {
                        addWord()
                    }
                Button("Add") {
                    addWord()
                }
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if viewModel.currentContextualStrings.isEmpty {
                Text("No custom vocabulary registered.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(viewModel.currentContextualStrings, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                viewModel.currentContextualStrings.removeAll { $0 == word }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { indexSet in
                        viewModel.currentContextualStrings.remove(atOffsets: indexSet)
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 120)
            }

            Text("\(viewModel.currentContextualStrings.count) / 100 words")
                .font(.caption)
                .foregroundStyle(viewModel.currentContextualStrings.count > 100 ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
        .onAppear {
            isNewWordFocused = true
        }
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard viewModel.currentContextualStrings.count < 100 else { return }
        guard !viewModel.currentContextualStrings.contains(trimmed) else {
            newWord = ""
            return
        }
        viewModel.currentContextualStrings.append(trimmed)
        newWord = ""
        isNewWordFocused = true
    }
}

// MARK: - Auto Replace Tab

private struct AutoReplaceTab: View {
    @Bindable var viewModel: SessionViewModel
    let localeDisplayName: String
    @State private var newFrom = ""
    @State private var newTo = ""
    @FocusState private var isFromFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automatically replace misrecognized words in transcription results. Rules are saved per source language.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Label(localeDisplayName, systemImage: "globe")
                .font(.subheadline.bold())

            HStack {
                TextField("From", text: $newFrom)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFromFocused)
                    .onSubmit {
                        addRule()
                    }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("To", text: $newTo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addRule()
                    }
                Button("Add") {
                    addRule()
                }
                .disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if viewModel.currentAutoReplacements.isEmpty {
                Text("No auto-replacement rules registered.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(viewModel.currentAutoReplacements) { rule in
                        HStack {
                            Text(rule.from)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(rule.to.isEmpty ? String(localized: "(delete)") : rule.to)
                                .foregroundStyle(rule.to.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                viewModel.currentAutoReplacements.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { indexSet in
                        viewModel.currentAutoReplacements.remove(atOffsets: indexSet)
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 120)
            }

            Text("\(viewModel.currentAutoReplacements.count) rules")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
        .onAppear {
            isFromFocused = true
        }
    }

    private func addRule() {
        let trimmedFrom = newFrom.trimmingCharacters(in: .whitespaces)
        guard !trimmedFrom.isEmpty else { return }
        // Prevent duplicate "from" entries
        guard !viewModel.currentAutoReplacements.contains(where: { $0.from == trimmedFrom }) else {
            newFrom = ""
            newTo = ""
            return
        }
        let trimmedTo = newTo.trimmingCharacters(in: .whitespaces)
        viewModel.currentAutoReplacements.append(AutoReplacement(from: trimmedFrom, to: trimmedTo))
        newFrom = ""
        newTo = ""
        isFromFocused = true
    }
}
