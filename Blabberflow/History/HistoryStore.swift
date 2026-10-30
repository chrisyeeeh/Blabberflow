import Foundation
import OSLog
import SwiftData

/// One saved dictation: what was heard and what was typed. Only kept while history is on.
@Model
final class HistoryEntry {
    var date: Date
    /// What was inserted, after the style rewrite.
    var text: String
    /// The raw transcript, before any rewrite.
    var heard: String
    var appName: String?
    var styleName: String
    /// Seconds from release to insert.
    var processingTime: Double

    init(date: Date, text: String, heard: String, appName: String?, styleName: String, processingTime: Double) {
        self.date = date
        self.text = text
        self.heard = heard
        self.appName = appName
        self.styleName = styleName
        self.processingTime = processingTime
    }
}

/// Counts for Insights: no text, so they're kept even when history is off.
@Model
final class DictationStat {
    var date: Date
    var words: Int
    /// Seconds spent speaking.
    var duration: Double

    init(date: Date, words: Int, duration: Double) {
        self.date = date
        self.words = words
        self.duration = duration
    }
}

private let log = Logger(subsystem: "com.chrisyeh.Blabberflow", category: "History")

/// The on-disk store in ~/Library/Application Support/Blabberflow.
final class HistoryStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init() {
        let folder = URL.applicationSupportDirectory.appending(path: "Blabberflow", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: folder.appending(path: "Blabberflow.store"))
        do {
            container = try ModelContainer(for: HistoryEntry.self, DictationStat.self, configurations: configuration)
        } catch {
            // A damaged store shouldn't stop dictation; fall back to memory for this launch.
            log.error("Couldn't open the history store: \(error.localizedDescription, privacy: .public)")
            container = try! ModelContainer(
                for: HistoryEntry.self, DictationStat.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }

    func add(_ entry: HistoryEntry) {
        context.insert(entry)
        save()
    }

    func add(_ stat: DictationStat) {
        context.insert(stat)
        save()
    }

    func latest(_ count: Int) -> [HistoryEntry] {
        var descriptor = FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = count
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Deletes history older than `days`; 0 keeps everything.
    func prune(olderThan days: Int) {
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) else { return }
        try? context.delete(model: HistoryEntry.self, where: #Predicate { $0.date < cutoff })
        save()
    }

    func clearHistory() {
        try? context.delete(model: HistoryEntry.self)
        save()
    }

    func resetInsights() {
        try? context.delete(model: DictationStat.self)
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            log.error("Couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
