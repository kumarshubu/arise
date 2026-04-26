import HealthKit
import Foundation

/// Centralises all HealthKit reads for the app.
/// - Requests read-only permission for step count.
/// - Provides async helpers to fetch today's steps and per-day totals.
@MainActor
final class HealthKitManager: ObservableObject {

    static let shared = HealthKitManager()

    // MARK: - State

    @Published private(set) var authorizationStatus: HKAuthorizationStatus = .notDetermined
    @Published private(set) var todaySteps: Int = 0

    private let store = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)

    static let goalSteps = 10_000

    // MARK: - Availability

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        guard isAvailable else { return }

        authorizationStatus = store.authorizationStatus(for: stepType)
        guard authorizationStatus == .notDetermined else { return }

        do {
            try await store.requestAuthorization(toShare: [], read: [stepType])
            authorizationStatus = store.authorizationStatus(for: stepType)
        } catch {
            print("HealthKit auth error: \(error.localizedDescription)")
        }
    }

    // MARK: - Today's Steps

    /// Fetches step count for today and updates `todaySteps`.
    func loadTodaySteps() async {
        guard isAvailable, store.authorizationStatus(for: stepType) == .sharingAuthorized else { return }
        todaySteps = await fetchSteps(for: Date())
    }

    // MARK: - Steps for a Specific Day

    /// Returns the step total for the calendar day containing `date`.
    func fetchSteps(for date: Date) async -> Int {
        guard isAvailable else { return 0 }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let error = error {
                    print("HealthKit steps query error: \(error.localizedDescription)")
                    continuation.resume(returning: 0)
                    return
                }
                let count = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: Int(count))
            }
            store.execute(query)
        }
    }

    // MARK: - Steps for Multiple Days

    /// Returns a dictionary of [dateKey: stepCount] for the given dates.
    /// Uses a single anchored query across the full date range for efficiency.
    func fetchSteps(for dates: [Date]) async -> [String: Int] {
        guard isAvailable, !dates.isEmpty else { return [:] }

        let calendar = Calendar.current
        let sorted = dates.sorted()
        guard let earliest = sorted.first, let latest = sorted.last else { return [:] }

        let rangeStart = calendar.startOfDay(for: earliest)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: latest)) else { return [:] }

        let predicate = HKQuery.predicateForSamples(withStart: rangeStart, end: rangeEnd, options: .strictStartDate)

        let interval = DateComponents(day: 1)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: rangeStart,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error = error {
                    print("HealthKit collection query error: \(error.localizedDescription)")
                    continuation.resume(returning: [:])
                    return
                }

                var dict: [String: Int] = [:]
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"

                results?.enumerateStatistics(from: rangeStart, to: rangeEnd) { stats, _ in
                    let key = formatter.string(from: stats.startDate)
                    let count = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    dict[key] = Int(count)
                }

                continuation.resume(returning: dict)
            }

            store.execute(query)
        }
    }
}
