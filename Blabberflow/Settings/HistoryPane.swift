import SwiftData
import SwiftUI

struct HistoryPane: View {
    @Bindable var model: AppModel
    @Query(sort: \HistoryEntry.date, order: .reverse) private var entries: [HistoryEntry]
    @State private var search = ""
    @State private var confirmingClear = false
    @State private var expanded: PersistentIdentifier?

    private let retentionOptions: [(days: Int, name: String)] = [
        (7, "1 week"), (30, "30 days"), (90, "90 days"), (365, "1 year"), (0, "Forever"),
    ]

    var body: some View {
        @Bindable var preferences = model.preferences
        Page(title: "History", subtitle: "Stored only on this Mac. Audio is never saved.") {
            Section {
                Toggle(isOn: $preferences.keepsHistory) {
                    Text("Keep history")
                    Text("When off, nothing you say is saved. Insights still count words and time.")
                }
                Picker("Keep for", selection: $preferences.historyRetentionDays) {
                    ForEach(retentionOptions, id: \.days) { option in
                        Text(option.name).tag(option.days)
                    }
                }
                .disabled(!preferences.keepsHistory)
                LabeledContent(entries.count == 1 ? "1 dictation saved" : "\(entries.count) dictations saved") {
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                        .disabled(entries.isEmpty)
                }
            }

            if entries.isEmpty {
                Section {
                    Text(preferences.keepsHistory
                         ? "Nothing yet. \(model.shortcutHint), and what you say shows up here."
                         : "History is off.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField("Search", text: $search, prompt: Text("Search history"))
                        .textFieldStyle(.roundedBorder)
                }
                ForEach(days, id: \.self) { day in
                    Section(title(for: day)) {
                        ForEach(filtered.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }) { entry in
                            HistoryRow(model: model, entry: entry, isExpanded: expanded == entry.persistentModelID) {
                                expanded = expanded == entry.persistentModelID ? nil : entry.persistentModelID
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This deletes every saved transcript on this Mac. Insights keep their counts.")
        }
        .onChange(of: preferences.historyRetentionDays) { _, days in
            model.history.prune(olderThan: days)
        }
    }

    private var filtered: [HistoryEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.text.localizedCaseInsensitiveContains(search)
                || $0.heard.localizedCaseInsensitiveContains(search)
                || ($0.appName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private var days: [Date] {
        var seen: [Date] = []
        for entry in filtered {
            let day = Calendar.current.startOfDay(for: entry.date)
            if seen.last != day { seen.append(day) }
        }
        return seen
    }

    private func title(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}


/// Time, app and text. Click to see what was heard next to what was typed, and to rewrite what was
/// heard in another style.
private struct HistoryRow: View {
    let model: AppModel
    let entry: HistoryEntry
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var isHovered = false
    @State private var confirmingDelete = false
    @State private var rewrite: (style: String, text: String)?
    @State private var rewritingStyle: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(entry.date, format: .dateTime.hour().minute())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(entry.appName ?? "—")
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                    .lineLimit(1)
                Text(entry.text)
                    .lineLimit(isExpanded ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button { model.copy(entry.text) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy")
                        .accessibilityLabel("Copy")
                    Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                        .help("Delete")
                        .accessibilityLabel("Delete")
                }
                .buttonStyle(.borderless)
                .opacity(isHovered || isExpanded ? 1 : 0)
            }

            if isExpanded {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Heard").font(.caption).foregroundStyle(.secondary)
                        Text("“\(entry.heard)”").italic().foregroundStyle(.secondary).textSelection(.enabled)
                        Menu {
                            ForEach(model.preferences.styles) { style in
                                Button(style.name) { rewrite(as: style) }
                            }
                        } label: {
                            Label("Rewrite as", systemImage: "wand.and.sparkles")
                        }
                        .fixedSize()
                        .disabled(rewritingStyle != nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        if let rewritingStyle {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Rewriting as \(rewritingStyle)…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let rewrite {
                            Text("Rewritten · \(rewrite.style)").font(.caption).foregroundStyle(.secondary)
                            Text(rewrite.text).textSelection(.enabled)
                            HStack {
                                Button("Copy") { model.copy(rewrite.text) }
                                Button("Paste") { model.pasteIntoLastApp(rewrite.text) }
                                    .help("Type it into the app you were last in")
                            }
                            .controlSize(.small)
                        } else {
                            Text("Typed · \(entry.styleName) · \(entry.processingTime, format: .number.precision(.fractionLength(1))) s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.text).textSelection(.enabled)
                        }
                        if let failure {
                            Text(failure).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 186)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Collapse" : "Show what was heard and rewrite it in another style")
        .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteHistory(entry) }
        } message: {
            Text("It's removed from History on this Mac. Insights keep their counts.")
        }
    }

    private func rewrite(as style: Style) {
        rewritingStyle = style.name
        failure = nil
        Task {
            do {
                rewrite = (style.name, try await model.preview(entry.heard, in: style))
            } catch {
                failure = "Couldn't rewrite: \(error.localizedDescription)"
            }
            rewritingStyle = nil
        }
    }
}
