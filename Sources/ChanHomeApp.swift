import SwiftUI
import UserNotifications

@main
struct ChanHomeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var home = HomeStore.shared
    @StateObject private var schedules = ScheduleStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(home)
                .environmentObject(schedules)
                .tint(.orange)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                home.becameActive()
                schedules.tick()
            case .background:
                home.enteredBackground()
                schedules.updateBackgroundMode()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ScheduleStore.registerCategories()
        ScheduleStore.shared.start()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == ScheduleKeys.runActionID,
              let raw = info["scheduleID"] as? String, let id = UUID(uuidString: raw) else { return }
        await ScheduleStore.runFromNotification(id: id)
    }
}
