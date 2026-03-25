import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SessionViewModel
    @State private var newWord = ""
    @FocusState private var isNewWordFocused: Bool

    private var localeDisplayName: String {
        let locale = Locale(identifier: viewModel.sourceLocaleIdentifier)
        return Locale.current.localizedString(forIdentifier: locale.identifier) ?? viewModel.sourceLocaleIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom Vocabulary")
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
            }

            Text("Add words or short phrases to improve speech recognition accuracy for specialized terminology. Vocabulary is saved per source language.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .frame(width: 360, height: 400)
        .onAppear {
            isNewWordFocused = true
        }
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !viewModel.currentContextualStrings.contains(trimmed) else {
            newWord = ""
            return
        }
        viewModel.currentContextualStrings.append(trimmed)
        newWord = ""
        isNewWordFocused = true
    }
}
