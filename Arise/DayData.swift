import Foundation

// MARK: - DayRecord

struct DayRecord: Identifiable {
    let id: String        // "yyyy-MM-dd"
    let date: Date
    let steps: Bool
    let noBinge: Bool
    let sleep: Bool
    let protein: Bool
    let workout: Bool
    let dopamine: Bool

    /// Actual step count from HealthKit. nil if HealthKit was unavailable or not yet loaded.
    var stepCount: Int?

    // MARK: Computed

    var score: Int {
        var t = 0
        if noBinge  { t += 2 }
        if sleep    { t += 2 }
        if steps    { t += 1 }
        if protein  { t += 1 }
        if workout  { t += 1 }
        if dopamine { t += 1 }
        return t
    }

    var isGoodDay: Bool { noBinge && sleep }

    var stepsGoalMet: Bool { (stepCount ?? 0) >= HealthKitManager.goalSteps }

    // MARK: Formatters (static to avoid per-call allocation)

    static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var shortLabel: String { DayRecord.shortFormatter.string(from: date) }
    var dateKey: String    { DayRecord.keyFormatter.string(from: date) }
}
