import Foundation

/// 해 뜨는 기상 알람 하나
struct WakeAlarm: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var hour = 7
    var minute = 0
    /// Calendar weekday (1 = 일 … 7 = 토). 비어 있으면 한 번만.
    var weekdays: [Int] = [2, 3, 4, 5, 6]
    var room = Room.defaultRoom
    /// 밝아지는 데 걸리는 시간(분): 10 / 15 / 20 / 30
    var rampMinutes = 15
    /// 마지막 밝기: 50 / 67 / 83 / 100
    var finalLevel = 100
    /// 기상 시각에 소리로도 깨우기
    var sound = true
    var snoozeEnabled = true
    var snoozeMinutes = 9
    /// 이 시각의 알람 한 번만 건너뛰기
    var skipDate: Date?
    var lastRun: Date?
    var lastResult: String?
    /// 한 번짜리 알람의 실제 날짜
    var onceDate: Date?

    var isOneShot: Bool { weekdays.isEmpty }

    /// 한 번짜리: date 이후 처음 오는 그 시각
    func computeOnceDate(from date: Date, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: date)
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let wake = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if wake > date { return wake }
        }
        return nil
    }

    var timeText: String { String(format: "%d:%02d", hour, minute) }

    /// 실제로 거치는 밝기 단계 (조명이 6단계로 맞춰짐: 17 → 33 → … → 마지막 밝기)
    var levels: [Int] {
        let steps = Device.brightnessSteps.filter { $0 <= finalLevel }
        return steps.isEmpty ? [Device.snapBrightness(finalLevel)] : steps
    }

    /// date 이후의 기상 시각들 (건너뛰기 포함, 그대로)
    func wakeTimes(after date: Date, limit: Int, calendar: Calendar = .current) -> [Date] {
        if isOneShot {
            guard let onceDate, onceDate > date else { return [] }
            return [onceDate]
        }
        var result: [Date] = []
        let start = calendar.startOfDay(for: date)
        for offset in 0...14 {
            guard result.count < limit,
                  let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if !weekdays.contains(calendar.component(.weekday, from: day)) { continue }
            if let wake = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), wake > date {
                result.append(wake)
            }
        }
        return result
    }

    /// 건너뛰기를 반영한 다음 기상 시각
    func nextWake(after date: Date) -> Date? {
        wakeTimes(after: date, limit: 3).first { !isSkipped($0) }
    }

    func isSkipped(_ wake: Date) -> Bool {
        guard let skipDate else { return false }
        return abs(skipDate.timeIntervalSince(wake)) < 60
    }

    /// 기상 시각 기준 조명 단계: (시각, 밝기). 첫 단계는 rampMinutes 전, 마지막은 기상 시각.
    func plan(for wake: Date) -> [RampStep] {
        let levels = self.levels
        guard levels.count > 1 else { return [RampStep(at: wake, level: levels[0])] }
        let total = TimeInterval(rampMinutes * 60)
        let gap = total / TimeInterval(levels.count - 1)
        return levels.enumerated().map { index, level in
            RampStep(at: wake.addingTimeInterval(-total + gap * TimeInterval(index)), level: level)
        }
    }
}

/// 조명 단계 하나. level == nil 이면 끄기.
struct RampStep: Codable, Equatable {
    var at: Date
    var level: Int?
}

/// 지금 진행 중인 임시 흐름 (취침 모드 · 테스트 · 다시 알림 후 복귀)
struct RunningRamp: Codable, Equatable {
    enum Kind: String, Codable { case sleep, test, snoozeReturn }
    var kind: Kind
    var room: String
    var steps: [RampStep]
    var applied = -1

    var start: Date { steps.first?.at ?? Date() }
    var end: Date { steps.last?.at ?? Date() }
    var title: String {
        switch kind {
        case .sleep: return "취침 모드"
        case .test: return "기상 조명 테스트"
        case .snoozeReturn: return "다시 알림"
        }
    }

    func progress(at date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(max(date.timeIntervalSince(start) / total, 0), 1)
    }
}

enum WakeFormat {
    /// "내일 오전 7:00" 같은 상대 표시
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "오늘" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "내일"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 EEEE"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter.string(from: date)
    }

    static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "H:mm"
        return formatter.string(from: date)
    }

    /// "남은 시간 7시간 32분"
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return "\(minutes)분 후" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)시간 후" : "\(hours)시간 \(rest)분 후"
    }
}
