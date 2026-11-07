import Foundation
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

/// 예약 실행 엔진 (서버 없음, iPhone 혼자 실행)
///  1. 앱이 살아 있으면(백그라운드 유지 포함) 15초마다 확인해 정시에 실행
///  2. 앱이 꺼져 있어 실행하지 못하면 예약 시각 90초 뒤 알림 → 알림의 [지금 실행]으로 바로 실행
///  3. 10분 넘게 늦은 예약은 실행하지 않고 '놓침'으로 기록 (늦게 불이 켜지는 일 방지)
enum ScheduleKeys {
    static let runActionID = "RUN_NOW"
    static let categoryID = "SCHEDULE"
    static let missedPrefix = "missed-"
    static let lateLimit: TimeInterval = 10 * 60

    static func missedID(_ id: UUID, _ fire: Date) -> String {
        "\(missedPrefix)\(id.uuidString)-\(Int(fire.timeIntervalSince1970))"
    }
}

@MainActor
final class ScheduleStore: ObservableObject {
    static let shared = ScheduleStore()

    @Published private(set) var schedules: [Schedule] = []
    @Published var backgroundEnabled: Bool { didSet { saveSettings(); updateBackgroundMode() } }
    @Published var notifyOnRun: Bool { didSet { saveSettings() } }
    @Published private(set) var running: Set<UUID> = []

    private let isDemo: Bool
    private var timer: Timer?
    private var started = false

    init() {
        let defaults = UserDefaults.standard
        isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
        backgroundEnabled = defaults.object(forKey: "bgEnabled") as? Bool ?? true
        notifyOnRun = defaults.object(forKey: "notifyOnRun") as? Bool ?? true
        if isDemo {
            schedules = Self.demoSchedules
        } else if let data = defaults.data(forKey: "schedules"),
                  let saved = try? JSONDecoder().decode([Schedule].self, from: data) {
            schedules = saved
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started, !isDemo else { return }
        started = true
        let now = Date()
        for index in schedules.indices where schedules[index].enabled && schedules[index].nextFire == nil {
            schedules[index].nextFire = schedules[index].next(after: now)
        }
        save()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in ScheduleStore.shared.tick() }
        }
        updateBackgroundMode()
        rescheduleNotifications()
    }

    /// 실행할 때가 된 예약 처리
    func tick() {
        guard !isDemo else { return }
        let now = Date()
        for index in schedules.indices {
            let schedule = schedules[index]
            guard schedule.enabled, let fire = schedule.nextFire, fire <= now else { continue }
            advance(index, after: now)
            if now.timeIntervalSince(fire) <= ScheduleKeys.lateLimit {
                let id = schedule.id
                Task { await self.run(id: id, occurrence: fire) }
            } else {
                schedules[index].lastRun = fire
                schedules[index].lastResult = "놓침 — 앱이 실행 중이 아니었어요"
            }
        }
        save()
    }

    private func advance(_ index: Int, after date: Date) {
        if schedules[index].isOneShot {
            schedules[index].enabled = false
            schedules[index].nextFire = nil
        } else {
            schedules[index].nextFire = schedules[index].next(after: date)
        }
    }

    // MARK: - Editing

    func upsert(_ schedule: Schedule) {
        var item = schedule
        item.nextFire = item.enabled ? item.next(after: Date()) : nil
        if let index = schedules.firstIndex(where: { $0.id == item.id }) {
            schedules[index] = item
        } else {
            schedules.append(item)
        }
        schedules.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        save()
        requestNotificationPermission()
        updateBackgroundMode()
        rescheduleNotifications()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].enabled = enabled
        schedules[index].nextFire = enabled ? schedules[index].next(after: Date()) : nil
        save()
        updateBackgroundMode()
        rescheduleNotifications()
    }

    func delete(_ id: UUID) {
        schedules.removeAll { $0.id == id }
        save()
        updateBackgroundMode()
        rescheduleNotifications()
    }

    // MARK: - Run

    /// occurrence: 예약된 실행 시각 (수동 실행이면 nil)
    func run(id: UUID, occurrence: Date?) async {
        guard let schedule = schedules.first(where: { $0.id == id }), !running.contains(id) else { return }
        running.insert(id)
        if let occurrence { cancelMissedNotification(id: id, fire: occurrence) }

        let task = BackgroundTaskBox()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "schedule") {
            UIApplication.shared.endBackgroundTask(task.id)
            task.id = .invalid
        }
        defer {
            running.remove(id)
            if task.id != .invalid { UIApplication.shared.endBackgroundTask(task.id) }
        }

        let place = Room.display(schedule.room)
        let result: String
        do {
            var message = "예약한 동작을 실행했어요."
            if !isDemo {
                let action = schedule.action, room = schedule.room
                message = try await BackgroundRunner.run { try await HomeActions.perform(action, room: room) }
            }
            result = "완료"
            if notifyOnRun {
                post(title: "\(place) · \(schedule.action.title)", body: message, scheduleID: nil)
            }
        } catch {
            result = "실패 — \(error.localizedDescription)"
            post(title: "\(place) · \(schedule.action.title) 실패", body: error.localizedDescription, scheduleID: id)
        }
        if let index = schedules.firstIndex(where: { $0.id == id }) {
            schedules[index].lastRun = Date()
            schedules[index].lastResult = result
        }
        save()
        rescheduleNotifications()
    }

    /// 알림의 [지금 실행] 버튼 (앱이 꺼져 있어도 백그라운드에서 호출됨)
    static func runFromNotification(id: UUID) async {
        let store = ScheduleStore.shared
        store.start()
        await store.run(id: id, occurrence: nil)
    }

    // MARK: - Background keep-alive

    var isKeepingAlive: Bool { KeepAlive.shared.isRunning }

    func updateBackgroundMode() {
        let needed = !isDemo && backgroundEnabled && HomeStore.shared.isSignedIn
            && (schedules.contains { $0.enabled } || WakeEngine.shared.needsBackground)
        if needed { KeepAlive.shared.start() } else { KeepAlive.shared.stop() }
        objectWillChange.send()
    }

    // MARK: - Notifications

    static func registerCategories() {
        let run = UNNotificationAction(identifier: ScheduleKeys.runActionID, title: "지금 실행", options: [])
        let category = UNNotificationCategory(identifier: ScheduleKeys.categoryID, actions: [run], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category, SystemAlarms.registerCategory()])
    }

    private func requestNotificationPermission() {
        guard !isDemo else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 앱이 꺼져 있어 실행되지 못한 경우를 대비한 알림 (실행에 성공하면 취소됨)
    private func rescheduleNotifications() {
        guard !isDemo else { return }
        let center = UNUserNotificationCenter.current()
        let items = schedules.filter(\.enabled).flatMap { schedule in
            schedule.upcoming(from: Date(), limit: 4).map { (schedule, $0) }
        }.sorted { $0.1 < $1.1 }
        let limited = Array(items.prefix(60))

        center.getPendingNotificationRequests { pending in
            let old = pending.map(\.identifier).filter { $0.hasPrefix(ScheduleKeys.missedPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for (schedule, fire) in limited {
                let content = UNMutableNotificationContent()
                content.title = "예약이 실행되지 않았어요"
                content.body = "\(Room.display(schedule.room)) · \(schedule.action.title) (\(schedule.timeText))"
                content.sound = .default
                content.categoryIdentifier = ScheduleKeys.categoryID
                content.userInfo = ["scheduleID": schedule.id.uuidString]
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                                 from: fire.addingTimeInterval(90))
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                center.add(UNNotificationRequest(identifier: ScheduleKeys.missedID(schedule.id, fire), content: content, trigger: trigger))
            }
        }
    }

    private func cancelMissedNotification(id: UUID, fire: Date) {
        let identifier = ScheduleKeys.missedID(id, fire)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func post(title: String, body: String, scheduleID: UUID?) {
        guard !isDemo else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let scheduleID {
            content.categoryIdentifier = ScheduleKeys.categoryID
            content.userInfo = ["scheduleID": scheduleID.uuidString]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Persistence

    private func save() {
        guard !isDemo, let data = try? JSONEncoder().encode(schedules) else { return }
        UserDefaults.standard.set(data, forKey: "schedules")
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(backgroundEnabled, forKey: "bgEnabled")
        defaults.set(notifyOnRun, forKey: "notifyOnRun")
    }

    private static var demoSchedules: [Schedule] {
        [
            Schedule(hour: 7, minute: 30, weekdays: [2, 3, 4, 5, 6], room: "침실3", action: .lightLevel(60),
                     lastRun: Date(), lastResult: "완료"),
            Schedule(enabled: true, hour: 23, minute: 30, weekdays: [1, 2, 3, 4, 5, 6, 7], room: "침실3", action: .light(false)),
            Schedule(enabled: false, hour: 18, minute: 0, weekdays: [1, 7], room: "침실3", action: .aircon(true, 26)),
        ]
    }
}
