import Foundation

enum ScheduleAction: Codable, Hashable {
    case light(Bool)
    case aircon(Bool, Int?)
    case heat(Bool, Int?)
    case sockets(Bool)

    var title: String {
        switch self {
        case .light(let on): return on ? "조명 켜기" : "조명 끄기"
        case .aircon(let on, let temp):
            if !on { return "에어컨 끄기" }
            return temp.map { "에어컨 \($0)°로 켜기" } ?? "에어컨 켜기"
        case .heat(let on, let temp):
            if !on { return "난방 끄기" }
            return temp.map { "난방 \($0)°로 켜기" } ?? "난방 켜기"
        case .sockets(let on): return on ? "콘센트 켜기" : "콘센트 끄기"
        }
    }

    var symbol: String {
        switch self {
        case .light: return "lightbulb"
        case .aircon: return "snowflake"
        case .heat: return "flame"
        case .sockets: return "powerplug"
        }
    }
}

struct Schedule: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var hour: Int
    var minute: Int
    /// Calendar weekday (1 = 일 … 7 = 토). 비어 있으면 한 번만 실행.
    var weekdays: [Int] = []
    var room: String
    var action: ScheduleAction
    var nextFire: Date?
    var lastRun: Date?
    var lastResult: String?

    var isOneShot: Bool { weekdays.isEmpty }

    /// date 이후 첫 실행 시각
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay) else { continue }
            if !isOneShot && !weekdays.contains(calendar.component(.weekday, from: day)) { continue }
            if let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), fire > date {
                return fire
            }
        }
        return nil
    }

    func upcoming(from date: Date, limit: Int) -> [Date] {
        var result: [Date] = []
        var cursor = date
        while result.count < limit, let fire = next(after: cursor) {
            result.append(fire)
            if isOneShot { break }
            cursor = fire
        }
        return result
    }

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    var repeatText: String {
        let set = Set(weekdays)
        if set.isEmpty { return "한 번" }
        if set.count == 7 { return "매일" }
        if set == [2, 3, 4, 5, 6] { return "주중" }
        if set == [1, 7] { return "주말" }
        return Weekday.ordered.filter { set.contains($0.value) }.map(\.short).joined(separator: " ")
    }
}

struct Weekday: Identifiable {
    let value: Int
    let short: String
    var id: Int { value }

    /// 월요일부터 표시
    static let ordered: [Weekday] = [
        Weekday(value: 2, short: "월"), Weekday(value: 3, short: "화"), Weekday(value: 4, short: "수"),
        Weekday(value: 5, short: "목"), Weekday(value: 6, short: "금"), Weekday(value: 7, short: "토"),
        Weekday(value: 1, short: "일"),
    ]
}
