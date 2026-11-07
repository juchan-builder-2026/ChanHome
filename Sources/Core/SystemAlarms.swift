import Foundation
import SwiftUI
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

enum WakeKeys {
    static let category = "WAKE"
    static let snoozeAction = "WAKE_SNOOZE"
    static let stopAction = "WAKE_STOP"
    static let prefix = "wake-"
}

/// 기상 시각의 '소리' 담당.
///  - iOS 26 이상 + 권한 허용: AlarmKit — 무음 모드·집중 모드에서도 시계 앱 알람처럼 울리고,
///    잠금 화면에 큰 [끄기] [n분 뒤] 버튼이 뜬다. 앱이 꺼져 있어도 울린다.
///  - 그 외: 소리 나는 알림으로 대신한다.
/// 다음 7번의 기상 시각을 미리 예약해 두고, 앱이 실행될 때마다 다시 맞춘다.
enum SystemAlarms {
    static var isAlarmKitAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// 화면 표시용 권한 상태
    static func permissionText() -> String {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return "시계 앱 알람처럼 울려요 (무음 모드에서도)"
            case .denied: return "알람 권한이 꺼져 있어 알림 소리로 대신해요 — 설정 → 집 → 알람"
            case .notDetermined: return "알람을 저장하면 권한을 물어봐요"
            @unknown default: return ""
            }
        }
        #endif
        return "iOS 26 미만이라 알림 소리로 깨워요"
    }

    static func requestAuthorization() async {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            _ = await AlarmKitBridge.requestAuthorization()
        }
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func registerCategory() -> UNNotificationCategory {
        let snooze = UNNotificationAction(identifier: WakeKeys.snoozeAction, title: "다시 알림", options: [])
        let stop = UNNotificationAction(identifier: WakeKeys.stopAction, title: "일어났어요", options: [])
        return UNNotificationCategory(identifier: WakeKeys.category, actions: [stop, snooze], intentIdentifiers: [], options: [])
    }

    /// 켜진 알람들의 다음 기상 시각(최대 7번)을 다시 예약
    static func sync(_ alarms: [WakeAlarm]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(WakeKeys.prefix) })

        var useAlarmKit = false
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            useAlarmKit = AlarmKitBridge.isAuthorized
            AlarmKitBridge.cancelScheduled()
        }
        #endif

        let now = Date()
        for alarm in alarms where alarm.enabled && alarm.sound {
            for wake in alarm.wakeTimes(after: now, limit: 7) where !alarm.isSkipped(wake) {
                await schedule(alarm, at: wake, isSnooze: false, useAlarmKit: useAlarmKit)
            }
        }
    }

    /// 다시 알림: n분 뒤 한 번 더
    static func scheduleSnooze(_ alarm: WakeAlarm, at date: Date) async {
        var useAlarmKit = false
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { useAlarmKit = AlarmKitBridge.isAuthorized }
        #endif
        await schedule(alarm, at: date, isSnooze: true, useAlarmKit: useAlarmKit)
    }

    /// 울리고 있는 AlarmKit 알람 멈추기
    static func stopAlerting(_ alarmID: String?) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let alarmID, let id = UUID(uuidString: alarmID) {
            AlarmKitBridge.stop(id)
        }
        #endif
    }

    private static func schedule(_ alarm: WakeAlarm, at date: Date, isSnooze: Bool, useAlarmKit: Bool) async {
        #if canImport(AlarmKit)
        if useAlarmKit, #available(iOS 26.0, *) {
            do {
                try await AlarmKitBridge.schedule(alarm, at: date, isSnooze: isSnooze)
                return
            } catch {
                // 실패하면 알림으로 대신
            }
        }
        #endif
        let content = UNMutableNotificationContent()
        content.title = isSnooze ? "다시 알림" : "일어날 시간이에요"
        content.body = "\(Room.display(alarm.room)) 조명 \(alarm.finalLevel)% · \(WakeFormat.time(date))"
        content.sound = .default
        content.interruptionLevel = .active
        content.categoryIdentifier = WakeKeys.category
        content.userInfo = ["wakeID": alarm.id.uuidString]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(
            identifier: "\(WakeKeys.prefix)\(alarm.id.uuidString)-\(Int(date.timeIntervalSince1970))",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct WakeAlarmMetadata: AlarmMetadata {
    var wakeID: String
}

@available(iOS 26.0, *)
enum AlarmKitBridge {
    private static var manager: AlarmManager { AlarmManager.shared }

    static var isAuthorized: Bool { manager.authorizationState == .authorized }

    static func requestAuthorization() async -> Bool {
        switch manager.authorizationState {
        case .authorized: return true
        case .denied: return false
        case .notDetermined:
            return (try? await manager.requestAuthorization()) == .authorized
        @unknown default: return false
        }
    }

    /// 예약만 된 알람 정리 (지금 울리고 있는 건 건드리지 않음)
    static func cancelScheduled() {
        guard let alarms = try? manager.alarms else { return }
        for alarm in alarms where alarm.state != .alerting {
            try? manager.cancel(id: alarm.id)
        }
    }

    static func stop(_ id: UUID) {
        try? manager.stop(id: id)
    }

    static func schedule(_ wake: WakeAlarm, at date: Date, isSnooze: Bool) async throws {
        let id = UUID()
        let title: LocalizedStringResource = isSnooze ? "다시 알림" : "일어날 시간이에요"
        let stopButton = AlarmButton(text: "끄기", textColor: .white, systemImageName: "sun.max.fill")
        let alert: AlarmPresentation.Alert
        if wake.snoozeEnabled {
            let snoozeButton = AlarmButton(text: "\(wake.snoozeMinutes)분 뒤", textColor: .white, systemImageName: "moon.zzz.fill")
            alert = AlarmPresentation.Alert(title: title, stopButton: stopButton,
                                            secondaryButton: snoozeButton, secondaryButtonBehavior: .custom)
        } else {
            alert = AlarmPresentation.Alert(title: title, stopButton: stopButton)
        }
        let attributes = AlarmAttributes<WakeAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: WakeAlarmMetadata(wakeID: wake.id.uuidString),
            tintColor: .orange)
        let stopIntent = WakeStopIntent(wakeID: wake.id.uuidString, alarmID: id.uuidString)
        let snoozeIntent: WakeSnoozeIntent? = wake.snoozeEnabled
            ? WakeSnoozeIntent(wakeID: wake.id.uuidString, alarmID: id.uuidString) : nil
        let configuration = AlarmManager.AlarmConfiguration<WakeAlarmMetadata>(
            countdownDuration: nil,
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: stopIntent,
            secondaryIntent: snoozeIntent)
        _ = try await manager.schedule(id: id, configuration: configuration)
    }
}
#endif
