import Foundation

/// controls/home.do 의 `_deviceListByType` 한 항목.
struct Device: Identifiable, Hashable, Codable {
    let uid: String
    let type: String          // light, aircon, heat, wallsocket, vent, gas, alloffswitch ...
    let name: String          // device_name (예: 침실3등, 에어컨, 콘센트1)
    let room: String          // operation.location_name (예: 침실3)
    var op: [String: String]  // operation 원문 (값은 문자열로 정규화)

    var id: String { uid }

    var status: String? { op["status"] }
    /// on/off 로 알 수 있으면 Bool, 상태 필드가 없으면 nil
    var isOn: Bool? {
        switch status {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }
    var setTemp: Int? { op["set_temp"].flatMap { Int($0) } }
    var currentTemp: Int? { op["current_temp"].flatMap { Int($0) } }
    var mode: String? { op["mode"] }
    /// 조명 밝기. 서버 형식(실측): value = "light_000_083" (색온도_밝기), options = "light_999_100" (최대값)
    var brightness: Int? {
        guard let raw = op["value"] else { return nil }
        let parts = raw.split(separator: "_")
        if parts.count == 3, parts[0] == "light", let level = Int(parts[2]) { return level }
        return nil
    }

    /// 밝기 조절 지원 여부: options 의 최대 밝기 값이 0보다 크면 지원
    var supportsBrightness: Bool {
        let parts = (op["options"] ?? "").split(separator: "_")
        if parts.count == 3, parts[0] == "light", let maxLevel = Int(parts[2]) { return maxLevel > 0 }
        return brightness != nil
    }

    /// 보낼 값: 색온도 자리는 현재 값을 그대로 유지 (예: light_000_050)
    func brightnessValue(_ level: Int) -> String {
        let parts = (op["value"] ?? "").split(separator: "_")
        let color = parts.count == 3 && parts[0] == "light" ? String(parts[1]) : "000"
        return "light_\(color)_" + String(format: "%03d", min(max(level, 1), 100))
    }

    /// 실측상 6단계로 맞춰짐 (30 → 33, 83, 100)
    static let brightnessSteps = [17, 33, 50, 67, 83, 100]
    static func snapBrightness(_ value: Int) -> Int {
        brightnessSteps.min { abs($0 - value) < abs($1 - value) } ?? 100
    }
    var wind: String? { op["wind_speed"] }

    /// "침실3등" → "조명", "거실1등" → "조명 1", "콘센트1" → "콘센트 1"
    var displayName: String {
        var rest = name
        if !room.isEmpty, rest.hasPrefix(room) { rest = String(rest.dropFirst(room.count)) }
        if type == "light" {
            if rest.isEmpty || rest == "등" { return "조명" }
            if rest.hasSuffix("등") { return "조명 " + rest.dropLast() }
        }
        if let digitStart = rest.firstIndex(where: { $0.isNumber }), digitStart != rest.startIndex,
           rest[digitStart...].allSatisfy({ $0.isNumber }) {
            return String(rest[..<digitStart]) + " " + String(rest[digitStart...])
        }
        return rest.isEmpty ? name : rest
    }

    static func parse(_ json: String) throws -> [Device] {
        guard let data = json.data(using: .utf8),
              let groups = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ElifeError.parse("기기 목록 형식이 달라요")
        }
        var result: [Device] = []
        for group in groups {
            let groupType = group["type"] as? String ?? ""
            for raw in (group["devices"] as? [[String: Any]]) ?? [] {
                var op: [String: String] = [:]
                for (key, value) in (raw["operation"] as? [String: Any]) ?? [:] where !(value is NSNull) {
                    op[key] = "\(value)"
                }
                let uid = "\(raw["uid"] ?? "")"
                guard !uid.isEmpty else { continue }
                result.append(Device(
                    uid: uid,
                    type: groupType.isEmpty ? (op["type"] ?? "") : groupType,
                    name: raw["device_name"] as? String ?? "",
                    room: op["location_name"] ?? (raw["location_name"] as? String) ?? "",
                    op: op
                ))
            }
        }
        return result
    }
}

enum Room {
    /// 화면에 보여줄 방 이름: 침실3 → 방 3
    static func display(_ room: String) -> String {
        if room.hasPrefix("침실"), let n = Int(room.dropFirst(2)) { return "방 \(n)" }
        return room
    }

    static let preferredOrder = ["침실3", "거실", "침실1", "침실2", "안방", "주방"]
    static let defaultRoom = "침실3"
}

enum AirconMode: String, CaseIterable {
    case cool, dehumi, fan, auto
    var title: String {
        switch self {
        case .cool: return "냉방"
        case .dehumi: return "제습"
        case .fan: return "송풍"
        case .auto: return "자동"
        }
    }
    static func title(_ raw: String?) -> String {
        guard let raw else { return "" }
        if raw == "heat" { return "난방" }
        if raw == "out" { return "외출" }
        return AirconMode(rawValue: raw)?.title ?? raw
    }
}

enum WindSpeed: String, CaseIterable {
    case low, middle, high, auto
    var title: String {
        switch self {
        case .low: return "약"
        case .middle: return "중"
        case .high: return "강"
        case .auto: return "자동"
        }
    }
}

enum ElifeError: LocalizedError, Equatable {
    case noLogin
    case needsCredentials
    case loginFailed(String)
    case notAuthorized
    case http(Int)
    case server(String)
    case parse(String)
    case network(String)
    case noDevice(String)

    var errorDescription: String? {
        switch self {
        case .noLogin: return "세션이 만료됐어요. 다시 연결해 주세요."
        case .needsCredentials: return "로그인이 필요해요."
        case .loginFailed(let m): return "로그인 실패: \(m)"
        case .notAuthorized: return "이 기기를 제어할 권한이 없어요."
        case .http(let c): return "서버 응답 오류 (HTTP \(c))"
        case .server(let m): return m.isEmpty ? "서버가 요청을 거절했어요." : "서버 오류: \(m)"
        case .parse(let m): return m
        case .network: return "인터넷 연결을 확인해 주세요."
        case .noDevice(let what): return "\(what)이(가) 이 방에 없어요."
        }
    }

    /// 재로그인으로 해결될 수 있는 오류
    var isSessionProblem: Bool {
        switch self {
        case .noLogin, .parse: return true
        case .http(let code): return code == 401 || code == 403
        default: return false
        }
    }
}
