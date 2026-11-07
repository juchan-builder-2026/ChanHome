import Foundation

enum PowerMode {
    case on, off, toggle
}

/// 화면 없이 실행하는 제어 (단축어 · Siri · 동작 버튼 · 일정 공용).
/// 실행할 때마다 기기 목록을 새로 읽어 방/종류로 찾고, 보낸 뒤 다시 읽어 실제 상태로 결과를 만든다.
/// 요청 형식은 앱 화면과 같다 (방 3에서 실측 확인한 형식).
enum HomeActions {
    private static var client: ElifeClient { ElifeClient.shared }

    // MARK: - Lights

    static func lights(room: String, mode: PowerMode) async throws -> (String, [Device]) {
        let lights = try await find(room: room, type: "light", name: "조명")
        let turnOn: Bool
        switch mode {
        case .on: turnOn = true
        case .off: turnOn = false
        case .toggle: turnOn = !lights.contains { $0.isOn == true }
        }
        for light in lights {
            try await client.controlAll(type: "light", uid: light.uid, control: turnOn ? "on" : "off")
        }
        let after = try await verified()
        var message = "\(Room.display(room)) 조명을 \(turnOn ? "켰어요" : "껐어요")"
        if turnOn, let level = after.first(where: { $0.room == room && $0.type == "light" })?.brightness {
            message += " (밝기 \(level)%)"
        }
        return (message, after)
    }

    static func brightness(room: String, level: Int) async throws -> (String, [Device]) {
        let lights = try await find(room: room, type: "light", name: "조명")
        let snapped = Device.snapBrightness(level)
        for light in lights {
            if light.isOn != true {
                try await client.controlAll(type: "light", uid: light.uid, control: "on")
            }
            try await client.control(type: "light", uid: light.uid, operation: ["value": light.brightnessValue(snapped)])
        }
        let after = try await verified()
        let actual = after.first(where: { $0.room == room && $0.type == "light" })?.brightness ?? snapped
        return ("\(Room.display(room)) 조명 밝기를 \(actual)%로 맞췄어요", after)
    }

    /// 기상/취침 조명 한 단계. level == nil 이면 끄기.
    /// 꺼진 조명을 켤 때는 밝기를 먼저 보내고 → 켜고 → 다시 밝기를 보낸다
    /// (켜는 순간 예전 밝기로 번쩍이지 않게).
    static func rampStep(room: String, level: Int?) async throws -> (String, [Device]) {
        let lights = try await find(room: room, type: "light", name: "조명")
        guard let level else {
            for light in lights where light.isOn != false {
                try await client.controlAll(type: "light", uid: light.uid, control: "off")
            }
            return ("\(Room.display(room)) 조명을 껐어요", try await verified())
        }
        let snapped = Device.snapBrightness(level)
        for light in lights {
            let value = light.brightnessValue(snapped)
            if light.isOn != true {
                try? await client.control(type: "light", uid: light.uid, operation: ["value": value])
                try await client.controlAll(type: "light", uid: light.uid, control: "on")
            }
            try await client.control(type: "light", uid: light.uid, operation: ["value": value])
        }
        let after = try await verified()
        let actual = after.first(where: { $0.room == room && $0.type == "light" })?.brightness ?? snapped
        return ("\(Room.display(room)) 조명 \(actual)%", after)
    }

    static func allLightsOff() async throws -> (String, [Device]) {
        let lights = try await client.fetchDevices().filter { $0.type == "light" && $0.isOn != false }
        for light in lights {
            try await client.controlAll(type: "light", uid: light.uid, control: "off")
        }
        let after: [Device]
        if lights.isEmpty {
            after = try await client.fetchDevices()
        } else {
            after = try await verified()
        }
        let stillOn = after.filter { $0.type == "light" && $0.isOn == true }.count
        return (stillOn == 0 ? "집 안 조명을 모두 껐어요" : "조명 \(stillOn)개가 아직 켜져 있어요", after)
    }

    // MARK: - Climate

    static func aircon(room: String, on: Bool, temperature: Int?) async throws -> (String, [Device]) {
        guard let device = try await find(room: room, type: "aircon", name: "에어컨").first else {
            throw ElifeError.noDevice("에어컨")
        }
        try await client.control(type: "aircon", uid: device.uid, operation: ["control": on ? "on" : "off"])
        var target: Int?
        if on, let temperature {
            let value = min(max(temperature, 18), 30)
            try await client.control(type: "aircon", uid: device.uid, operation: ["set_temp": String(value)])
            target = value
        }
        let after = try await verified()
        let message = on
            ? "\(Room.display(room)) 에어컨을 켰어요" + (target.map { " (\($0)°)" } ?? "")
            : "\(Room.display(room)) 에어컨을 껐어요"
        return (message, after)
    }

    static func heat(room: String, on: Bool, temperature: Int?) async throws -> (String, [Device]) {
        guard let device = try await find(room: room, type: "heat", name: "난방").first else {
            throw ElifeError.noDevice("난방")
        }
        try await client.control(type: "heat", uid: device.uid, operation: ["control": on ? "on" : "off"])
        var target: Int?
        if on, let temperature {
            let value = min(max(temperature, 15), 30)
            try await client.control(type: "heat", uid: device.uid, operation: ["set_temp": String(value)])
            target = value
        }
        let after = try await verified()
        let message = on
            ? "\(Room.display(room)) 난방을 켰어요" + (target.map { " (\($0)°)" } ?? "")
            : "\(Room.display(room)) 난방을 껐어요"
        return (message, after)
    }

    // MARK: - Others

    static func sockets(room: String, on: Bool) async throws -> (String, [Device]) {
        let sockets = try await find(room: room, type: "wallsocket", name: "콘센트")
        for socket in sockets {
            try await client.controlAll(type: "wallsocket", uid: socket.uid, control: on ? "on" : "off")
        }
        let after = try await verified()
        return ("\(Room.display(room)) 콘센트 \(sockets.count)개를 \(on ? "켰어요" : "껐어요")", after)
    }

    static func vent(on: Bool) async throws -> (String, [Device]) {
        guard let vent = try await client.fetchDevices().first(where: { $0.type == "vent" }) else {
            throw ElifeError.noDevice("환기")
        }
        try await client.control(type: "vent", uid: vent.uid, operation: ["control": on ? "on" : "off"])
        return ("환기를 \(on ? "켰어요" : "껐어요")", try await verified())
    }

    static func closeGas() async throws -> (String, [Device]) {
        guard let gas = try await client.fetchDevices().first(where: { $0.type == "gas" }) else {
            throw ElifeError.noDevice("가스 밸브")
        }
        if gas.status != "close" {
            try await client.control(type: "gas", uid: gas.uid, operation: ["control": "close"])
        }
        let after = try await verified()
        let closed = after.first(where: { $0.type == "gas" })?.status == "close"
        return (closed ? "가스 밸브가 잠겨 있어요" : "가스 잠금을 요청했어요", after)
    }

    static func status(room: String) async throws -> (String, [Device]) {
        let list = try await client.fetchDevices()
        return (summary(room: room, devices: list), list)
    }

    /// 사람이 읽는 방 상태 요약
    static func summary(room: String, devices: [Device]) -> String {
        let inRoom = devices.filter { $0.room == room }
        var parts: [String] = []
        for light in inRoom where light.type == "light" {
            if light.isOn == true {
                parts.append("\(light.displayName) 켜짐" + (light.brightness.map { " \($0)%" } ?? ""))
            } else {
                parts.append("\(light.displayName) 꺼짐")
            }
        }
        for ac in inRoom where ac.type == "aircon" {
            let state = ac.isOn == true ? "켜짐 · \(AirconMode.title(ac.mode))" : "꺼짐"
            let temps = [ac.setTemp.map { "\($0)° 설정" }, ac.currentTemp.map { "현재 \($0)°" }].compactMap { $0 }
            parts.append("에어컨 \(state)" + (temps.isEmpty ? "" : " (\(temps.joined(separator: ", ")))"))
        }
        for heat in inRoom where heat.type == "heat" {
            let temps = [heat.setTemp.map { "\($0)° 설정" }, heat.currentTemp.map { "현재 \($0)°" }].compactMap { $0 }
            parts.append("난방 " + (temps.isEmpty ? "" : temps.joined(separator: ", ")))
        }
        let sockets = inRoom.filter { $0.type == "wallsocket" }
        if !sockets.isEmpty {
            parts.append("콘센트 \(sockets.count)개 중 \(sockets.filter { $0.isOn == true }.count)개 켜짐")
        }
        if parts.isEmpty { return "\(Room.display(room))에 기기가 없어요" }
        return "\(Room.display(room)) — " + parts.joined(separator: ", ")
    }

    // MARK: - Schedules

    static func perform(_ action: ScheduleAction, room: String) async throws -> (String, [Device]) {
        switch action {
        case .light(let on): return try await lights(room: room, mode: on ? .on : .off)
        case .lightLevel(let level): return try await brightness(room: room, level: level)
        case .aircon(let on, let temp): return try await aircon(room: room, on: on, temperature: temp)
        case .heat(let on, let temp): return try await heat(room: room, on: on, temperature: temp)
        case .sockets(let on): return try await sockets(room: room, on: on)
        }
    }

    // MARK: - Helpers

    private static func find(room: String, type: String, name: String) async throws -> [Device] {
        let devices = try await client.fetchDevices().filter { $0.room == room && $0.type == type }
        guard !devices.isEmpty else { throw ElifeError.noDevice(name) }
        return devices
    }

    /// 제어 직후 서버 반영까지 잠깐 기다렸다가 다시 읽는다 (실측: 1~3초)
    private static func verified() async throws -> [Device] {
        try await Task.sleep(for: .milliseconds(1500))
        return try await client.fetchDevices()
    }
}

/// 화면 없이 실행할 때: 끝나면 바로 로그아웃하고, 앱 화면의 상태도 갱신
enum BackgroundRunner {
    static func run(_ work: () async throws -> (String, [Device])) async throws -> String {
        do {
            let (message, devices) = try await work()
            await ElifeClient.shared.logoutNow()
            await HomeStore.ingest(devices)
            return message
        } catch {
            await ElifeClient.shared.logoutNow()
            throw error
        }
    }
}
