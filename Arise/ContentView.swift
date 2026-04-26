import SwiftUI
import FirebaseFirestore
import UserNotifications

// MARK: - Root Tab Container

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            TodayTab()
                .tabItem {
                    Label("Today", systemImage: "checkmark.circle.fill")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "chart.line.uptrend.xyaxis")
                }
        }
    }
}

// MARK: - Today Tab

struct TodayTab: View {

    // MARK: - HealthKit
    @StateObject private var hk = HealthKitManager.shared

    // MARK: - State
    @State private var steps = false
    @State private var noBinge = false
    @State private var sleep = false
    @State private var protein = false
    @State private var workout = false
    @State private var dopamine = false

    @State private var goodDaysCount = 0

    // Guard flag: suppresses onChange-triggered saves while loading data
    @State private var isLoading = false

    let db = Firestore.firestore()

    // Fixed user ID key — replace with Auth.auth().currentUser?.uid for multi-user support
    private let userID = "shubham"

    // MARK: - Score
    var score: Int {
        var total = 0
        if noBinge  { total += 2 }
        if sleep    { total += 2 }
        if steps    { total += 1 }
        if protein  { total += 1 }
        if workout  { total += 1 }
        if dopamine { total += 1 }
        return total
    }

    var isGoodDay: Bool {
        noBinge && sleep
    }

    var body: some View {
        VStack(spacing: 20) {

            Text("Score: \(score)/8")
                .font(.largeTitle)
                .bold()

            Text(isGoodDay ? "Win Day 🔥" : "Fix Today ⚠️")
                .foregroundColor(isGoodDay ? .green : .red)

            Divider()

            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Steps (10k+)", isOn: $steps)
                    if hk.isAvailable && hk.todaySteps > 0 {
                        let pct = min(Double(hk.todaySteps) / Double(HealthKitManager.goalSteps), 1.0)
                        HStack(spacing: 6) {
                            Image(systemName: "figure.walk")
                                .font(.caption2)
                                .foregroundColor(steps ? .green : .blue)
                            Text("\(hk.todaySteps.formatted()) steps")
                                .font(.caption2)
                                .foregroundColor(steps ? .green : .secondary)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 3)
                                    Capsule().fill(steps ? Color.green : Color.blue)
                                        .frame(width: geo.size.width * pct, height: 3)
                                }
                            }
                            .frame(height: 3)
                        }
                        .padding(.leading, 2)
                    }
                }
                Toggle("No Night Binge",      isOn: $noBinge)
                Toggle("Sleep Before 12:30",  isOn: $sleep)
                Toggle("Protein Goal",        isOn: $protein)
                Toggle("Workout Done",        isOn: $workout)
                Toggle("Dopamine Control",    isOn: $dopamine)
            }
            .padding()

            Divider()

            Text("\(goodDaysCount)/10 good days")
                .font(.headline)

            if goodDaysCount >= 7 {
                Text("Reward Unlocked 🎉")
                    .foregroundColor(.green)
                    .bold()
            }

            Spacer()
        }
        .padding()
        .onAppear {
            // Load local data immediately, then sync from Firebase.
            // isLoading prevents the onChange handlers from writing
            // data back to Firestore while values are being populated.
            isLoading = true
            loadToday()
            scheduleNightNotification()
            loadFromFirebase()         // async; clears isLoading when done
            Task {
                await hk.requestAuthorizationIfNeeded()
                await hk.loadTodaySteps()
            }
        }
        .onChange(of: hk.todaySteps) { _, newSteps in
            // Auto-check the steps toggle when HealthKit reports >= 10k steps.
            // Only update if the value would change, to avoid triggering a
            // spurious Firestore write.
            let goalMet = newSteps >= HealthKitManager.goalSteps
            if steps != goalMet {
                steps = goalMet
            }
        }
        .onChange(of: steps)    { _ in if !isLoading { update() } }
        .onChange(of: noBinge)  { _ in if !isLoading { update() } }
        .onChange(of: sleep)    { _ in if !isLoading { update() } }
        .onChange(of: protein)  { _ in if !isLoading { update() } }
        .onChange(of: workout)  { _ in if !isLoading { update() } }
        .onChange(of: dopamine) { _ in if !isLoading { update() } }
    }

    // MARK: - Update (user-driven change)
    func update() {
        saveToday()
        saveToFirebase()
        calculateGoodDays()
    }

    // MARK: - Date Key
    func dateKey(offset: Int = 0) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Save Local
    // Stores each field as an individual UserDefaults entry under a
    // prefixed key. Storing a [String: Bool] dict directly via
    // UserDefaults.set(_:forKey:) is unreliable (requires NSCoding-
    // compatible types and the dict is silently dropped on some OS
    // versions when read back with dictionary(forKey:)).
    func saveToday() {
        let key = dateKey()
        UserDefaults.standard.set(steps,    forKey: "\(key).steps")
        UserDefaults.standard.set(noBinge,  forKey: "\(key).noBinge")
        UserDefaults.standard.set(sleep,    forKey: "\(key).sleep")
        UserDefaults.standard.set(protein,  forKey: "\(key).protein")
        UserDefaults.standard.set(workout,  forKey: "\(key).workout")
        UserDefaults.standard.set(dopamine, forKey: "\(key).dopamine")
    }

    // MARK: - Save Firebase
    func saveToFirebase() {
        let data: [String: Any] = [
            "steps":    steps,
            "noBinge":  noBinge,
            "sleep":    sleep,
            "protein":  protein,
            "workout":  workout,
            "dopamine": dopamine,
            "timestamp": Timestamp()
        ]

        db.collection("users")
            .document(userID)
            .collection("days")
            .document(dateKey())
            .setData(data) { error in
                if let error = error {
                    print("Firestore write error: \(error.localizedDescription)")
                }
            }
    }

    // MARK: - Load Local
    func loadToday() {
        let key = dateKey()
        // Check whether any entry exists for today before assuming defaults
        if UserDefaults.standard.object(forKey: "\(key).steps") != nil {
            steps    = UserDefaults.standard.bool(forKey: "\(key).steps")
            noBinge  = UserDefaults.standard.bool(forKey: "\(key).noBinge")
            sleep    = UserDefaults.standard.bool(forKey: "\(key).sleep")
            protein  = UserDefaults.standard.bool(forKey: "\(key).protein")
            workout  = UserDefaults.standard.bool(forKey: "\(key).workout")
            dopamine = UserDefaults.standard.bool(forKey: "\(key).dopamine")
        } else {
            reset()
        }
    }

    // MARK: - Load Firebase
    func loadFromFirebase() {
        db.collection("users")
            .document(userID)
            .collection("days")
            .document(dateKey())
            .getDocument { document, error in
                defer { isLoading = false }

                if let error = error {
                    print("Firestore read error: \(error.localizedDescription)")
                    return
                }

                guard let document = document, document.exists,
                      let data = document.data() else { return }

                steps    = data["steps"]    as? Bool ?? false
                noBinge  = data["noBinge"]  as? Bool ?? false
                sleep    = data["sleep"]    as? Bool ?? false
                protein  = data["protein"]  as? Bool ?? false
                workout  = data["workout"]  as? Bool ?? false
                dopamine = data["dopamine"] as? Bool ?? false

                // Persist the authoritative Firebase state locally,
                // then recalculate the streak from remote history.
                saveToday()
                loadGoodDaysFromFirebase()
            }
    }

    // MARK: - Notification (10 PM)
    func scheduleNightNotification() {
        let center = UNUserNotificationCenter.current()

        // Remove only this app's specific reminder, not all notifications
        center.removePendingNotificationRequests(withIdentifiers: ["night_reminder"])

        let content = UNMutableNotificationContent()
        content.title = "Win your day"
        content.body  = "No binge. Sleep on time."

        var dateComponents = DateComponents()
        dateComponents.hour   = 22
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents,
            repeats: true
        )

        let request = UNNotificationRequest(
            identifier: "night_reminder",
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error = error {
                print("Notification scheduling error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Reset
    func reset() {
        steps    = false
        noBinge  = false
        sleep    = false
        protein  = false
        workout  = false
        dopamine = false
    }

    // MARK: - Good Days (local cache)
    // Reads from UserDefaults for speed; used after user-driven updates.
    func calculateGoodDays() {
        var count = 0
        for i in 0..<10 {
            let key = dateKey(offset: -i)
            // Only count days that have been saved (key exists)
            guard UserDefaults.standard.object(forKey: "\(key).noBinge") != nil else { continue }
            let nb = UserDefaults.standard.bool(forKey: "\(key).noBinge")
            let sl = UserDefaults.standard.bool(forKey: "\(key).sleep")
            if nb && sl { count += 1 }
        }
        goodDaysCount = count
    }

    // MARK: - Good Days (Firebase source of truth)
    // Fetches the last 10 days from Firestore so the streak is correct
    // even on a fresh install where UserDefaults is empty.
    func loadGoodDaysFromFirebase() {
        let keys = (0..<10).map { dateKey(offset: -$0) }
        var count = 0
        let group = DispatchGroup()

        for key in keys {
            group.enter()
            db.collection("users")
                .document(userID)
                .collection("days")
                .document(key)
                .getDocument { document, _ in
                    defer { group.leave() }
                    guard let data = document?.data() else { return }
                    let nb = data["noBinge"] as? Bool ?? false
                    let sl = data["sleep"]   as? Bool ?? false
                    if nb && sl { count += 1 }
                    // Cache result locally so calculateGoodDays() is accurate offline
                    UserDefaults.standard.set(nb, forKey: "\(key).noBinge")
                    UserDefaults.standard.set(sl, forKey: "\(key).sleep")
                }
        }

        group.notify(queue: .main) {
            goodDaysCount = count
        }
    }
}

#Preview {
    TodayTab()
}
