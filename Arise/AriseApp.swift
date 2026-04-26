import SwiftUI
import Firebase
import UserNotifications

@main
struct AriseApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermission()
        return true
    }

    // MARK: - Notification Permission
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                ) { granted, error in
                    if let error = error {
                        print("Notification permission error: \(error.localizedDescription)")
                    } else {
                        print("Notification permission granted: \(granted)")
                    }
                }
            case .denied:
                print("Notifications denied — user must enable in Settings")
            default:
                break
            }
        }
    }
}
