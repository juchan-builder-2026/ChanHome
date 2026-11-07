import SwiftUI
import UserNotifications

@main
struct ChanHomeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var home = HomeStore.shared
    @StateObject private var schedules = ScheduleStore.shared
    @StateObject private var wake = WakeEngine.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(home)
                .environmentObject(schedules)
                .environmentObject(wake)
                .tint(.orange)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                home.becameActive()
                schedules.tick()
                wake.tick()
                wake.resync()
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
        WakeEngine.shared.start()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let wakeID = info["wakeID"] as? String {
            switch response.actionIdentifier {
            case WakeKeys.snoozeAction:
                await WakeEngine.handleSnooze(wakeID: wakeID, alarmID: nil)
            case WakeKeys.stopAction, UNNotificationDefaultActionIdentifier:
                await WakeEngine.handleStop(wakeID: wakeID, alarmID: nil)
            default:
                break
            }
            return
        }
        guard response.actionIdentifier == ScheduleKeys.runActionID,
              let raw = info["scheduleID"] as? String, let id = UUID(uuidString: raw) else { return }
        await ScheduleStore.runFromNotification(id: id)
    }
}
