import Foundation
import SwiftUI
import UIKit

/// 해 뜨는 기상 알람 + 취침 모드 엔진.
///
/// 기상 (예: 7:00, 15분, 마지막 100%):
///   6:45 17% → 6:48 33% → 6:51 50% → 6:54 67% → 6:57 83% → 7:00 100% + 알람 소리
///   - 조명 단계는 앱이 백그라운드에 살아 있을 때(무음 오디오 대기) 5초마다 확인해 실행.
///   - 늦게 깨어나도(앱 재시작 등) 지금 시각에 맞는 단계로 바로 맞춘다. 이미 지난 단계를 되풀이하지 않음.
///   - 알람 소리는 AlarmKit 이 따로 울리므로 앱이 꺼져 있어도 울린다.
///   - [끄기]: 조명을 마지막 밝기로 확실히 맞춘다 (앱이 꺼져 있어 단계가 빠졌어도).
///   - [n분 뒤]: 조명을 33%로 낮췄다가 n분 뒤 다시 마지막 밝기 + 알람.
/// 취침: 지금 밝기에서 한 단계씩 낮추다 마지막에 끈다.
@MainActor
final class WakeEngine: ObservableObject {
    static let shared = WakeEngine()

    @Published private(set) var alarms: [WakeAlarm] = []
    @Published private(set) var running: RunningRamp?
    @Published private(set) var lastMessage: String?
    @Published private(set) var permissionText = ""
    @Published private(set) var now = Date()

    let isDemo: Bool
    private var applied: [String: Int] = [:]
    private var stepTask: Task<Void, Never>?
    private var queuedStep: (room: String, level: Int?)?
    private var timer: Timer?
    private var started = false

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
        if isDemo {
            alarms = Self.demoAlarms
        } else if let data = UserDefaults.standard.data(forKey: "wakeAlarms"),
                  let saved = try? JSONDecoder().decode([WakeAlarm].self, from: data) {
            alarms = saved
        }
        if let data = UserDefaults.standard.data(forKey: "wakeRunning"),
           let saved = try? JSONDecoder().decode(RunningRamp.self, from: data), saved.end > Date() {
            running = saved
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in WakeEngine.shared.tick() }
        }
        guard !isDemo else { return }
        tick()
        resync()
    }

    var needsBackground: Bool {
        !isDemo && (alarms.contains { $0.enabled } || running != nil)
    }

    /// 다음 기상 (켜진 알람 중 가장 빠른 것)
    var nextUp: (alarm: WakeAlarm, wake: Date)? {
        alarms.filter(\.enabled)
            .compactMap { alarm in alarm.nextWake(after: now).map { (alarm, $0) } }
            .min { $0.1 < $1.1 }
    }

    // MARK: - Tick

    func tick() {
        now = Date()
        guard !isDemo else { return }
        var changed = false

        for index in alarms.indices where alarms[index].enabled {
            let alarm = alarms[index]
            // 지금 진행 중이거나 곧 시작할 기상 (기상 시각 2분 뒤까지 유효)
            guard let wake = alarm.wakeTimes(after: now.addingTimeInterval(-120), limit: 2)
                .first(where: { !alarm.isSkipped($0) }) else { continue }
            let plan = alarm.plan(for: wake)
            guard let first = plan.first, now >= first.at else { continue }
            guard let due = plan.lastIndex(where: { $0.at <= now }) else { continue }
            let key = "\(alarm.id.uuidString)-\(Int(wake.timeIntervalSince1970))"
            if due > (applied[key] ?? -1) {
                applied[key] = due
                apply(room: alarm.room, level: plan[due].level)
                if due == plan.count - 1 {
                    alarms[index].lastRun = wake
                    alarms[index].lastResult = "\(WakeFormat.time(wake)) 조명 \(alarm.finalLevel)%"
                    changed = true
                }
            }
        }

        // 지난 건너뛰기 정리, 지난 한 번짜리 알람 끄기
        for index in alarms.indices {
            if let skip = alarms[index].skipDate, skip < now.addingTimeInterval(-300) {
                alarms[index].skipDate = nil
                changed = true
            }
            if alarms[index].enabled, alarms[index].isOneShot,
               alarms[index].wakeTimes(after: now.addingTimeInterval(-180), limit: 1).isEmpty {
                alarms[index].enabled = false
                changed = true
            }
        }

        if var ramp = running, let due = ramp.steps.lastIndex(where: { $0.at <= now }), due > ramp.applied {
            ramp.applied = due
            running = ramp
            apply(room: ramp.room, level: ramp.steps[due].level)
            if due == ramp.steps.count - 1 { finishRunning() }
            saveRunning()
        }

        if changed {
            save()
            ScheduleStore.shared.updateBackgroundMode()
        }
    }

    private func finishRunning() {
        running = nil
        saveRunning()
        ScheduleStore.shared.updateBackgroundMode()
    }

    // MARK: - Light steps

    /// 단계 실행. 이전 단계가 아직 진행 중이면 가장 최근 단계만 이어서 실행.
    private func apply(room: String, level: Int?) {
        if stepTask != nil {
            queuedStep = (room, level)
            return
        }
        stepTask = Task {
            await self.applyNow(room: room, level: level)
            self.stepTask = nil
            if let next = self.queuedStep {
                self.queuedStep = nil
                self.apply(room: next.room, level: next.level)
            }
        }
    }

    /// 단계 하나를 끝까지 기다려서 실행 (단축어·알람 버튼처럼 앱이 곧 멈출 수 있을 때)
    func applyNow(room: String, level: Int?) async {
        if isDemo { return }
        let task = BackgroundTaskBox()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "wake-step") {
            UIApplication.shared.endBackgroundTask(task.id)
            task.id = .invalid
        }
        defer { if task.id != .invalid { UIApplication.shared.endBackgroundTask(task.id) } }
        do {
            lastMessage = try await BackgroundRunner.run { try await HomeActions.rampStep(room: room, level: level) }
        } catch {
            lastMessage = "조명 실패 — \(error.localizedDescription)"
        }
    }

    // MARK: - Editing

    func upsert(_ alarm: WakeAlarm) {
        var item = alarm
        item.skipDate = nil
        if item.isOneShot { item.onceDate = item.computeOnceDate(from: Date()) }
        if let index = alarms.firstIndex(where: { $0.id == item.id }) {
            alarms[index] = item
        } else {
            alarms.append(item)
        }
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        changedAlarms(requestPermission: item.enabled)
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].enabled = enabled
        alarms[index].skipDate = nil
        if enabled && alarms[index].isOneShot {
            alarms[index].onceDate = alarms[index].computeOnceDate(from: Date())
        }
        changedAlarms(requestPermission: enabled)
    }

    func delete(_ id: UUID) {
        alarms.removeAll { $0.id == id }
        changedAlarms(requestPermission: false)
    }

    /// 다음 한 번만 건너뛰기 / 취소
    func toggleSkip(_ id: UUID) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        if alarms[index].skipDate != nil {
            alarms[index].skipDate = nil
        } else {
            alarms[index].skipDate = alarms[index].wakeTimes(after: Date(), limit: 1).first
        }
        changedAlarms(requestPermission: false)
    }

    private func changedAlarms(requestPermission: Bool) {
        save()
        ScheduleStore.shared.updateBackgroundMode()
        guard !isDemo else { return }
        Task {
            if requestPermission { await SystemAlarms.requestAuthorization() }
            await SystemAlarms.sync(self.alarms)
            self.permissionText = SystemAlarms.permissionText()
        }
    }

    func resync() {
        guard !isDemo else { return }
        Task {
            await SystemAlarms.sync(self.alarms)
            self.permissionText = SystemAlarms.permissionText()
        }
    }

    // MARK: - Sleep / test

    /// 취침 모드: 지금 밝기에서 한 단계씩 낮추다 끈다
    @discardableResult
    func startSleep(room: String = Room.defaultRoom, minutes: Int) -> String {
        let light = HomeStore.shared.devices(in: room, type: "light").first
        if light?.isOn == false {
            return "\(Room.display(room)) 조명이 이미 꺼져 있어요"
        }
        let current = light.map { HomeStore.shared.brightness(of: $0) } ?? 100
        var levels: [Int?] = Device.brightnessSteps.filter { $0 < current }.reversed().map { Optional($0) }
        levels.append(nil)
        let gap = TimeInterval(minutes * 60) / TimeInterval(levels.count)
        let start = Date()
        let steps = levels.enumerated().map { index, level in
            RampStep(at: start.addingTimeInterval(gap * TimeInterval(index + 1)), level: level)
        }
        running = RunningRamp(kind: .sleep, room: room, steps: steps)
        saveRunning()
        ScheduleStore.shared.updateBackgroundMode()
        return "\(minutes)분 동안 \(Room.display(room)) 조명을 서서히 끌게요. 잘 자요"
    }

    /// 기상 조명 미리보기: 단계들을 6초 간격으로 빠르게
    func startTest(_ alarm: WakeAlarm) {
        let start = Date()
        let steps = alarm.levels.enumerated().map { index, level in
            RampStep(at: start.addingTimeInterval(6 * TimeInterval(index)), level: level)
        }
        running = RunningRamp(kind: .test, room: alarm.room, steps: steps)
        saveRunning()
        ScheduleStore.shared.updateBackgroundMode()
        tick()
    }

    func cancelRunning() {
        finishRunning()
    }

    // MARK: - Alarm buttons (AlarmKit / 알림)

    /// [끄기]: 마지막 밝기로 확실히 맞춘다
    static func handleStop(wakeID: String, alarmID: String?) async {
        SystemAlarms.stopAlerting(alarmID)
        let engine = WakeEngine.shared
        engine.start()
        guard let alarm = engine.alarms.first(where: { $0.id.uuidString == wakeID }) else { return }
        if engine.running?.kind == .snoozeReturn { engine.finishRunning() }
        await engine.applyNow(room: alarm.room, level: alarm.finalLevel)
        if let index = engine.alarms.firstIndex(where: { $0.id == alarm.id }) {
            engine.alarms[index].lastRun = Date()
            engine.alarms[index].lastResult = "\(WakeFormat.time(Date()))에 일어남"
            engine.save()
        }
    }

    /// [n분 뒤]: 조명을 33%로 낮추고, n분 뒤 다시 마지막 밝기 + 알람
    static func handleSnooze(wakeID: String, alarmID: String?) async {
        SystemAlarms.stopAlerting(alarmID)
        let engine = WakeEngine.shared
        engine.start()
        guard let alarm = engine.alarms.first(where: { $0.id.uuidString == wakeID }) else { return }
        let back = Date().addingTimeInterval(TimeInterval(alarm.snoozeMinutes * 60))
        engine.running = RunningRamp(kind: .snoozeReturn, room: alarm.room,
                                     steps: [RampStep(at: back, level: alarm.finalLevel)])
        engine.saveRunning()
        ScheduleStore.shared.updateBackgroundMode()
        if alarm.sound { await SystemAlarms.scheduleSnooze(alarm, at: back) }
        await engine.applyNow(room: alarm.room, level: min(33, alarm.finalLevel))
    }

    /// 단축어: 다음 알람 건너뛰기
    static func skipNextFromIntent() -> String {
        let engine = WakeEngine.shared
        engine.start()
        guard let next = engine.nextUp else { return "켜져 있는 기상 알람이 없어요" }
        engine.toggleSkip(next.alarm.id)
        return "\(WakeFormat.dayLabel(next.wake)) \(WakeFormat.time(next.wake)) 알람을 한 번 건너뛸게요"
    }

    static func statusText() -> String {
        let engine = WakeEngine.shared
        engine.now = Date()
        guard let next = engine.nextUp else { return "켜져 있는 기상 알람이 없어요" }
        let first = next.alarm.plan(for: next.wake).first?.at ?? next.wake
        return "다음 알람은 \(WakeFormat.dayLabel(next.wake)) \(WakeFormat.time(next.wake))이에요. "
            + "\(WakeFormat.shortTime(first))부터 \(Room.display(next.alarm.room)) 조명이 밝아져요"
    }

    static func sleepFromIntent(minutes: Int) async -> String {
        let engine = WakeEngine.shared
        engine.start()
        if HomeStore.shared.devices.isEmpty { await HomeStore.shared.refresh(quiet: true) }
        let message = engine.startSleep(minutes: minutes)
        if let first = engine.running?.steps.first, engine.running?.kind == .sleep {
            // 첫 단계는 바로 (앱이 백그라운드에서 곧 멈춰도 한 단계는 확실히)
            engine.running?.applied = 0
            engine.saveRunning()
            await engine.applyNow(room: engine.running?.room ?? Room.defaultRoom, level: first.level)
        }
        return message
    }

    // MARK: - Persistence

    private func save() {
        guard !isDemo, let data = try? JSONEncoder().encode(alarms) else { return }
        UserDefaults.standard.set(data, forKey: "wakeAlarms")
    }

    private func saveRunning() {
        guard !isDemo else { return }
        if let running, let data = try? JSONEncoder().encode(running) {
            UserDefaults.standard.set(data, forKey: "wakeRunning")
        } else {
            UserDefaults.standard.removeObject(forKey: "wakeRunning")
        }
    }

    private static var demoAlarms: [WakeAlarm] {
        [
            WakeAlarm(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6], rampMinutes: 15, finalLevel: 100,
                      lastRun: Date().addingTimeInterval(-86_400), lastResult: "오전 7:02에 일어남"),
            WakeAlarm(enabled: false, hour: 9, minute: 30, weekdays: [1, 7], rampMinutes: 30, finalLevel: 83, sound: false),
        ]
    }
}
