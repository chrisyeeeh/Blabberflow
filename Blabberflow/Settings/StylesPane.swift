import SwiftUI

struct StylesPane: View {
    @Bindable var model: AppModel
    @State private var editing: Style?

    var body: some View {
        @Bindable var preferences = model.preferences
        Page(title: "Styles", subtitle: "Apple Intelligence rewrites what you said in the tone you pick, staying close to your words.") {
            if model.appleIntelligence != .ready {
                Section {
                    AppleIntelligenceRow(status: model.appleIntelligence)
                } footer: {
                    Text("Until it's ready, every style inserts exactly what you said.")
                }
            }

            Section {
                Picker("Main shortcut uses", selection: $preferences.defaultStyleID) {
                    ForEach(preferences.styles) { style in
                        Text(style.name).tag(style.id)
                    }
                }
            } footer: {
                Text("\(model.preferences.dictationShortcut.display) dictates in this style. Give other styles their own shortcut to switch on the fly.")
            }

            Section("Styles") {
                ForEach(preferences.styles) { style in
                    StyleRow(style: style, isDefault: style.id == preferences.defaultStyleID) {
                        editing = style
                    }
                }
                Button {
                    editing = Style(name: "New style", instructions: "")
                } label: {
                    Label("Add Style…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .sheet(item: $editing) { style in
            StyleEditor(model: model, style: style, isNew: !preferences.styles.contains { $0.id == style.id })
        }
    }
}

private struct StyleRow: View {
    let style: Style
    let isDefault: Bool
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(style.name).fontWeight(.medium)
                    if isDefault {
                        Text("Main shortcut")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                Text(style.isLiteral ? "Exactly what you said, with dictionary spellings. No rewriting." : style.instructions)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if let shortcut = style.shortcut {
                Text(shortcut.display)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Edit…", action: edit)
        }
        .padding(.vertical, 2)
    }
}

private struct StyleEditor: View {
    let model: AppModel
    @State var style: Style
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var sample = "um so yeah I think we should push the launch to like Friday no wait Thursday and uh loop in the design team"
    @State private var output: String?
    @State private var failure: String?
    @State private var isRewriting = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $style.name)
                        .disabled(style.isLiteral)
                }

                if !style.isLiteral {
                    Section {
                        TextEditor(text: $style.instructions)
                            .font(.body)
                            .frame(minHeight: 96)
                            .scrollContentBackground(.hidden)
                    } header: {
                        Text("How to rewrite")
                    } footer: {
                        Text("Describe the tone. BlabberFlow already tells Apple Intelligence to keep your meaning and never answer what you said.")
                    }
                }

                Section("Shortcut") {
                    LabeledContent("Dictate in this style") {
                        ShortcutField(optional: $style.shortcut) { model.isRecordingShortcut = $0 }
                    }
                    if let conflict {
                        Label("\(conflict) already uses this shortcut.", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Try it") {
                    TextField("You said", text: $sample, axis: .vertical)
                        .lineLimit(2...4)
                    HStack {
                        Button("Rewrite", action: rewrite)
                            .disabled(isRewriting || sample.isEmpty || (!style.isLiteral && model.appleIntelligence != .ready))
                        if isRewriting { ProgressView().controlSize(.small) }
                    }
                    if let output {
                        Text(output)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let failure {
                        Text(failure).foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew, !style.isLiteral {
                    Button("Delete Style", role: .destructive, action: delete)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(style.name.trimmingCharacters(in: .whitespaces).isEmpty || (!style.isLiteral && style.instructions.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 540, height: 620)
    }

    /// Another binding that already uses this style's shortcut; the first one wins in the hotkey monitor.
    private var conflict: String? {
        guard let shortcut = style.shortcut else { return nil }
        if shortcut == model.preferences.dictationShortcut { return "The main dictation shortcut" }
        return model.preferences.styles.first { $0.id != style.id && $0.shortcut == shortcut }?.name
    }

    private func rewrite() {
        isRewriting = true
        output = nil
        failure = nil
        Task {
            do {
                output = try await model.preview(sample, in: style)
            } catch {
                failure = "Apple Intelligence couldn't rewrite that: \(error.localizedDescription)"
            }
            isRewriting = false
        }
    }

    private func save() {
        var styles = model.preferences.styles
        if let index = styles.firstIndex(where: { $0.id == style.id }) {
            styles[index] = style
        } else {
            styles.append(style)
        }
        model.preferences.styles = styles
        dismiss()
    }

    private func delete() {
        model.preferences.styles.removeAll { $0.id == style.id }
        if model.preferences.defaultStyleID == style.id {
            model.preferences.defaultStyleID = Style.literalID
        }
        dismiss()
    }
}
