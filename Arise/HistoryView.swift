import SwiftUI
import Charts
import FirebaseFirestore

// MARK: - ViewModel

@MainActor
class HistoryViewModel: ObservableObject {
    @Published var records: [DayRecord] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()
    private let userID = "shubham"

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func load(days: Int = 30) {
        isLoading = true
        errorMessage = nil
        records = []

        Task {
            // 1. Request HealthKit access
            await HealthKitManager.shared.requestAuthorizationIfNeeded()

            // 2. Fetch Firestore data
            let firestoreRecords = await fetchFromFirestore(days: days)

            // 3. Fetch HealthKit step data for the same date range
            let dates = firestoreRecords.map(\.date)
            let stepsByKey = await HealthKitManager.shared.fetchSteps(for: dates)

            // 4. Merge step counts into records
            records = firestoreRecords.map { record in
                var r = record
                r.stepCount = stepsByKey[record.dateKey]
                return r
            }

            isLoading = false
        }
    }

    // MARK: - Firestore fetch

    private func fetchFromFirestore(days: Int) async -> [DayRecord] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return [] }

        return await withCheckedContinuation { continuation in
            db.collection("users")
                .document(userID)
                .collection("days")
                .whereField("timestamp", isGreaterThanOrEqualTo: Timestamp(date: cutoff))
                .order(by: "timestamp", descending: false)
                .getDocuments { snapshot, error in
                    if let error = error {
                        print("Firestore history error: \(error.localizedDescription)")
                        continuation.resume(returning: [])
                        return
                    }

                    let formatter = HistoryViewModel.keyFormatter
                    let fetched: [DayRecord] = (snapshot?.documents ?? []).compactMap { doc in
                        guard let date = formatter.date(from: doc.documentID) else { return nil }
                        let data = doc.data()
                        return DayRecord(
                            id: doc.documentID,
                            date: date,
                            steps:    data["steps"]    as? Bool ?? false,
                            noBinge:  data["noBinge"]  as? Bool ?? false,
                            sleep:    data["sleep"]    as? Bool ?? false,
                            protein:  data["protein"]  as? Bool ?? false,
                            workout:  data["workout"]  as? Bool ?? false,
                            dopamine: data["dopamine"] as? Bool ?? false
                        )
                    }
                    continuation.resume(returning: fetched)
                }
        }
    }
}

// MARK: - History View

struct HistoryView: View {
    @StateObject private var vm = HistoryViewModel()
    @State private var selectedRange = 14

    private var visibleRecords: [DayRecord] {
        Array(vm.records.suffix(selectedRange))
    }

    private var averageScore: Double {
        guard !visibleRecords.isEmpty else { return 0 }
        return Double(visibleRecords.map(\.score).reduce(0, +)) / Double(visibleRecords.count)
    }

    private var goodDayCount: Int {
        visibleRecords.filter(\.isGoodDay).count
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView("Loading history…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.records.isEmpty {
                    ContentUnavailableView(
                        "No Data Yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Start tracking days to see your trend here.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            rangePicker
                            summaryCards
                            scoreTrendChart
                            stepsTrendChart
                            habitBreakdown
                            dayList
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .task { vm.load(days: 30) }
        }
    }

    // MARK: - Range Picker

    private var rangePicker: some View {
        Picker("Range", selection: $selectedRange) {
            Text("7d").tag(7)
            Text("14d").tag(14)
            Text("30d").tag(30)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            StatCard(title: "Avg Score", value: String(format: "%.1f/8", averageScore), color: .blue)
            StatCard(title: "Good Days", value: "\(goodDayCount)/\(visibleRecords.count)", color: .green)
            StatCard(title: "Best",      value: "\(visibleRecords.map(\.score).max() ?? 0)/8", color: .orange)
        }
    }

    // MARK: - Score Trend Chart

    private var scoreTrendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Score Trend")
                .font(.headline)

            Chart {
                ForEach(visibleRecords) { record in
                    AreaMark(
                        x: .value("Date", record.date),
                        y: .value("Score", record.score)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .blue.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                ForEach(visibleRecords) { record in
                    LineMark(
                        x: .value("Date", record.date),
                        y: .value("Score", record.score)
                    )
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                }
                ForEach(visibleRecords) { record in
                    PointMark(
                        x: .value("Date", record.date),
                        y: .value("Score", record.score)
                    )
                    .foregroundStyle(record.isGoodDay ? Color.green : Color.red)
                    .symbolSize(50)
                }
                RuleMark(y: .value("Average", averageScore))
                    .foregroundStyle(Color.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    .annotation(position: .trailing) {
                        Text("avg").font(.caption2).foregroundColor(.orange)
                    }
            }
            .chartYScale(domain: 0...8)
            .chartXAxis { xAxisMarks }
            .chartYAxis {
                AxisMarks(values: [0, 2, 4, 6, 8]) { _ in
                    AxisGridLine(); AxisValueLabel()
                }
            }
            .frame(height: 200)

            HStack(spacing: 16) {
                LegendDot(color: .green,  label: "Good day")
                LegendDot(color: .red,    label: "Fix day")
                LegendDot(color: .orange, label: "Average", dashed: true)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Steps Trend Chart

    private var stepsTrendChart: some View {
        let hasStepsData = visibleRecords.contains { $0.stepCount != nil }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Daily Steps")
                    .font(.headline)
                Spacer()
                Text("Goal: \(HealthKitManager.goalSteps / 1000)k")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !hasStepsData {
                Text("Steps data unavailable — grant Health access in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 120)
            } else {
                Chart {
                    // Bar per day
                    ForEach(visibleRecords) { record in
                        BarMark(
                            x: .value("Date", record.date, unit: .day),
                            y: .value("Steps", record.stepCount ?? 0)
                        )
                        .foregroundStyle(
                            (record.stepCount ?? 0) >= HealthKitManager.goalSteps
                                ? Color.green.gradient
                                : Color.blue.opacity(0.6).gradient
                        )
                        .cornerRadius(3)
                    }

                    // Goal line at 10k
                    RuleMark(y: .value("Goal", HealthKitManager.goalSteps))
                        .foregroundStyle(Color.orange.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .annotation(position: .trailing) {
                            Text("10k").font(.caption2).foregroundColor(.orange)
                        }
                }
                .chartXAxis { xAxisMarks }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text(v >= 1000 ? "\(v / 1000)k" : "\(v)")
                            }
                        }
                    }
                }
                .frame(height: 180)

                HStack(spacing: 16) {
                    LegendDot(color: .green,  label: "Goal met")
                    LegendDot(color: .blue,   label: "Below goal")
                    LegendDot(color: .orange, label: "10k goal", dashed: true)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Habit Breakdown

    private var habitBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Habit Completion")
                .font(.headline)

            let habits = habitCompletionRates()

            Chart(habits, id: \.name) { habit in
                BarMark(
                    x: .value("Rate", habit.rate),
                    y: .value("Habit", habit.name)
                )
                .foregroundStyle(barColor(for: habit.rate))
                .cornerRadius(4)

                RuleMark(x: .value("Target", 1.0))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
            .chartXScale(domain: 0...1)
            .chartXAxis {
                AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v * 100))%")
                        }
                    }
                }
            }
            .frame(height: 180)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private struct HabitRate { let name: String; let rate: Double }

    private func habitCompletionRates() -> [HabitRate] {
        let n = Double(visibleRecords.count)
        guard n > 0 else { return [] }
        return [
            HabitRate(name: "No Binge",  rate: Double(visibleRecords.filter(\.noBinge).count)  / n),
            HabitRate(name: "Sleep",     rate: Double(visibleRecords.filter(\.sleep).count)    / n),
            HabitRate(name: "Steps",     rate: Double(visibleRecords.filter(\.steps).count)    / n),
            HabitRate(name: "Protein",   rate: Double(visibleRecords.filter(\.protein).count)  / n),
            HabitRate(name: "Workout",   rate: Double(visibleRecords.filter(\.workout).count)  / n),
            HabitRate(name: "Dopamine",  rate: Double(visibleRecords.filter(\.dopamine).count) / n),
        ]
    }

    private func barColor(for rate: Double) -> Color {
        switch rate {
        case 0.75...: return .green
        case 0.5..<0.75: return .orange
        default: return .red
        }
    }

    // MARK: - Day List

    private var dayList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily Log")
                .font(.headline)
            ForEach(visibleRecords.reversed()) { record in
                DayRow(record: record)
            }
        }
    }

    // MARK: - Shared axis marks

    @AxisContentBuilder
    private var xAxisMarks: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: strideCount)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
    }

    private var strideCount: Int {
        selectedRange <= 7 ? 1 : (selectedRange <= 14 ? 2 : 5)
    }
}

// MARK: - Supporting Views

private struct StatCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title2).bold().foregroundColor(color)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String
    var dashed = false

    var body: some View {
        HStack(spacing: 4) {
            if dashed {
                Rectangle().fill(color).frame(width: 14, height: 2)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(label)
        }
    }
}

private struct DayRow: View {
    let record: DayRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.shortLabel).font(.subheadline).bold()
                    Text(record.isGoodDay ? "Win Day 🔥" : "Fix Day ⚠️")
                        .font(.caption)
                        .foregroundColor(record.isGoodDay ? .green : .red)
                }
                Spacer()
                ScoreBadge(score: record.score)
            }

            // Step count row (shown when HealthKit data is available)
            if let stepCount = record.stepCount {
                StepsRow(stepCount: stepCount)
            }

            // Habit dots
            HStack(spacing: 6) {
                HabitDot(label: "👟", active: record.steps)
                HabitDot(label: "🚫", active: record.noBinge)
                HabitDot(label: "🌙", active: record.sleep)
                HabitDot(label: "🥩", active: record.protein)
                HabitDot(label: "💪", active: record.workout)
                HabitDot(label: "🧠", active: record.dopamine)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct StepsRow: View {
    let stepCount: Int

    private var goalMet: Bool { stepCount >= HealthKitManager.goalSteps }
    private var progress: Double { min(Double(stepCount) / Double(HealthKitManager.goalSteps), 1.0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "figure.walk")
                    .font(.caption)
                    .foregroundColor(goalMet ? .green : .blue)
                Text(stepCount.formatted())
                    .font(.caption).bold()
                    .foregroundColor(goalMet ? .green : .primary)
                Text("/ \(HealthKitManager.goalSteps.formatted()) steps")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if goalMet {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(goalMet ? Color.green : Color.blue)
                        .frame(width: geo.size.width * progress, height: 4)
                }
            }
            .frame(height: 4)
        }
    }
}

private struct ScoreBadge: View {
    let score: Int
    private var color: Color {
        switch score {
        case 7...8: return .green
        case 4...6: return .orange
        default:    return .red
        }
    }
    var body: some View {
        Text("\(score)/8")
            .font(.headline).foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color).clipShape(Capsule())
    }
}

private struct HabitDot: View {
    let label: String
    let active: Bool
    var body: some View {
        Text(label)
            .font(.caption).padding(4)
            .background(active ? Color.green.opacity(0.2) : Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(active ? 1 : 0.4)
    }
}

#Preview {
    HistoryView()
}
