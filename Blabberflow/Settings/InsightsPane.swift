import Charts
import SwiftData
import SwiftUI

struct InsightsPane: View {
    let model: AppModel
    @Query(sort: \DictationStat.date) private var stats: [DictationStat]
    @State private var confirmingReset = false

    /// Typical typing speed, for "time saved".
    private let typingWordsPerMinute = 40.0

    var body: some View {
        Page(title: "Insights", subtitle: "Counted on this Mac from word counts and timing only. No text is kept here.") {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    StatTile(value: totalWords.formatted(), label: "Words dictated")
                    StatTile(value: wordsThisWeek.formatted(), label: "This week")
                    StatTile(value: averageWPM.map { "\($0)" } ?? "—", label: "Words per minute")
                    StatTile(value: timeSaved, label: "Saved vs typing")
                    StatTile(value: streak == 1 ? "1 day" : "\(streak) days", label: "Current streak")
                    StatTile(value: stats.count.formatted(), label: "Dictations")
                }
                .padding(.vertical, 4)
            }

            Section("Activity") {
                ActivityGrid(wordsByDay: wordsByDay)
                    .padding(.vertical, 4)
            }

            Section("Speaking speed, last 30 days") {
                if speedByDay.isEmpty {
                    Text("Dictate a few times and your speed shows up here.")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(speedByDay, id: \.day) { point in
                        LineMark(x: .value("Day", point.day, unit: .day), y: .value("Words per minute", point.wpm))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Brand.gradientTop)
                        PointMark(x: .value("Day", point.day, unit: .day), y: .value("Words per minute", point.wpm))
                            .foregroundStyle(Brand.gradientTop)
                            .symbolSize(24)
                    }
                    .chartYAxisLabel("wpm")
                    .frame(height: 160)
                    .padding(.vertical, 4)
                }
            }

            Section {
                LabeledContent("Start counting from zero") {
                    Button("Reset Insights…", role: .destructive) { confirmingReset = true }
                        .disabled(stats.isEmpty)
                }
            }
        }
        .confirmationDialog("Reset Insights?", isPresented: $confirmingReset) {
            Button("Reset Insights", role: .destructive) { model.resetInsights() }
        } message: {
            Text("This deletes all word counts and timings. History isn't affected.")
        }
    }

    // MARK: Numbers

    private var totalWords: Int { stats.reduce(0) { $0 + $1.words } }

    private var wordsThisWeek: Int {
        guard let start = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start else { return 0 }
        return stats.filter { $0.date >= start }.reduce(0) { $0 + $1.words }
    }

    /// Ignores very short holds, which say more about reaction time than speaking speed.
    private var timed: [DictationStat] { stats.filter { $0.duration >= 1.5 && $0.words > 0 } }

    private var averageWPM: Int? {
        let minutes = timed.reduce(0) { $0 + $1.duration } / 60
        guard minutes > 0 else { return nil }
        return Int((Double(timed.reduce(0) { $0 + $1.words }) / minutes).rounded())
    }

    private var timeSaved: String {
        let typingMinutes = Double(totalWords) / typingWordsPerMinute
        let speakingMinutes = stats.reduce(0) { $0 + $1.duration } / 60
        let saved = max(0, typingMinutes - speakingMinutes)
        return Duration.seconds(saved * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    private var wordsByDay: [Date: Int] {
        stats.reduce(into: [:]) { $0[Calendar.current.startOfDay(for: $1.date), default: 0] += $1.words }
    }

    /// Days in a row with at least one dictation, counting back from today (or yesterday, if today has none yet).
    private var streak: Int {
        let calendar = Calendar.current
        let days = wordsByDay
        var day = calendar.startOfDay(for: .now)
        if days[day] == nil, let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        var count = 0
        while days[day] != nil {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    private var speedByDay: [(day: Date, wpm: Double)] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) else { return [] }
        let grouped = Dictionary(grouping: timed.filter { $0.date >= cutoff }) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.map { day, stats in
            let minutes = stats.reduce(0) { $0 + $1.duration } / 60
            return (day, Double(stats.reduce(0) { $0 + $1.words }) / minutes)
        }
        .sorted { $0.day < $1.day }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// A year of days as a GitHub-style grid: one column per week, shaded by words dictated.
private struct ActivityGrid: View {
    let wordsByDay: [Date: Int]

    private let weeks = 52
    private let cell: CGFloat = 9
    private let gap: CGFloat = 3

    var body: some View {
        let columns = weekColumns
        let maxWords = max(wordsByDay.values.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: gap) {
                ForEach(columns.indices, id: \.self) { index in
                    VStack(spacing: gap) {
                        ForEach(columns[index], id: \.self) { day in
                            let words = wordsByDay[day] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: words, max: maxWords))
                                .frame(width: cell, height: cell)
                                .opacity(day > .now ? 0 : 1)
                                .help("\(words.formatted()) words · \(day.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.caption).foregroundStyle(.secondary)
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(level: level))
                        .frame(width: cell, height: cell)
                }
                Text("More").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Dictation activity over the past year")
        .accessibilityValue("\(wordsByDay.values.reduce(0, +).formatted()) words on \(wordsByDay.count) days")
    }

    /// 52 weeks ending this week; each column runs from the calendar's first weekday.
    private var weekColumns: [[Date]] {
        let calendar = Calendar.current
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) else { return [] }
        return (0..<weeks).map { week in
            (0..<7).compactMap { day in
                calendar.date(byAdding: .day, value: week * 7 + day, to: start).map { calendar.startOfDay(for: $0) }
            }
        }
    }

    private func color(for words: Int, max: Int) -> Color {
        guard words > 0 else { return color(level: 0) }
        let share = Double(words) / Double(max)
        return color(level: share > 0.75 ? 4 : share > 0.5 ? 3 : share > 0.25 ? 2 : 1)
    }

    private func color(level: Int) -> Color {
        switch level {
        case 0: Color.secondary.opacity(0.15)
        case 1: Brand.gradientTop.opacity(0.35)
        case 2: Brand.gradientTop.opacity(0.6)
        case 3: Brand.gradientTop.opacity(0.85)
        default: Brand.gradientBottom
        }
    }
}
