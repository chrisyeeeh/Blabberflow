import SwiftUI

struct DictionaryPane: View {
    @Bindable var model: AppModel
    @State private var newTerm = ""

    private var trimmed: String { newTerm.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Page(title: "Dictionary", subtitle: "Names, words and acronyms Blabberflow should always get right.") {
            Section {
                HStack {
                    TextField("Add a word, name or acronym", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(trimmed.isEmpty)
                }
            } footer: {
                Text("Type each one the way you want it written, like GitHub, Siobhan or OKR. Blabberflow listens out for them and fixes their spelling and capitals, even when you say “a p i” or “git hub”.")
            }

            Section(model.preferences.dictionary.isEmpty ? "Words" : "\(model.preferences.dictionary.count) words") {
                if model.preferences.dictionary.isEmpty {
                    Text("Nothing yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.preferences.dictionary.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                model.preferences.dictionary.removeAll { $0 == term }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove \(term)")
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let term = trimmed
        guard !term.isEmpty else { return }
        if !model.preferences.dictionary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            model.preferences.dictionary.append(term)
        }
        newTerm = ""
    }
}
