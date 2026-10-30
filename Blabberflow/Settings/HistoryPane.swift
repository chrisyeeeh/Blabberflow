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
                            HistoryRow(entry: entry, isExpanded: expanded == entry.persistentModelID) {
                                expanded = expanded == entry.persistentModelID ? nil : entry.persistentModelID
                            } copy: {
                                model.copy(entry.text)
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

/// Time, app and text; click to compare what was heard with what was typed.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let isExpanded: Bool
    let toggle: () -> Void
    let copy: () -> Void

    @State private var isHovered = false

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
                Button(action: copy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .opacity(isHovered || isExpanded ? 1 : 0)
                .help("Copy")
                .accessibilityLabel("Copy")
            }
            if isExpanded, entry.heard != entry.text {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Heard").font(.caption).foregroundStyle(.secondary)
                        Text("“\(entry.heard)”").italic().foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Typed · \(entry.styleName) · \(entry.processingTime, format: .number.precision(.fractionLength(1))) s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.text).textSelection(.enabled)
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
        .accessibilityHint(isExpanded ? "Collapse" : "Show what was heard and what was typed")
    }
}
