import Foundation
import SwiftUI
import UIKit

/// 화면 상태 + 기기 제어. 모든 제어는 사용자가 누른 그 동작만 그대로 보낸다.
/// 로그인은 조작(또는 당겨서 새로고침)할 때만 잠깐 하고 바로 로그아웃한다.
/// 화면에는 마지막으로 확인한 상태를 보여준다.
@MainActor
final class HomeStore: ObservableObject {
    static let shared = HomeStore()

    @Published private(set) var devices: [Device] = []
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var busy: Set<String> = []
    @Published var message: String?
    @Published var selectedRoom: String {
        didSet { UserDefaults.standard.set(selectedRoom, forKey: "selectedRoom") }
    }

    let isDemo: Bool
    private var verifyTask: Task<Void, Never>?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        isDemo = arguments.contains("-demo")
        selectedRoom = UserDefaults.standard.string(forKey: "selectedRoom") ?? Room.defaultRoom
        if isDemo {
            isSignedIn = !arguments.contains("-demoLogin")
            devices = DemoData.devices
            lastUpdated = Date().addingTimeInterval(-180)
            selectedRoom = Room.defaultRoom
        } else {
            isSignedIn = CredentialStore.load() != nil
            loadCache()
        }
    }

    // MARK: - Queries

    var rooms: [String] {
        var seen: [String] = []
        for device in devices where ["light", "aircon", "heat", "wallsocket"].contains(device.type) {
            if !device.room.isEmpty && !seen.contains(device.room) { seen.append(device.room) }
        }
        return seen.sorted {
            (Room.preferredOrder.firstIndex(of: $0) ?? 99, $0) < (Room.preferredOrder.firstIndex(of: $1) ?? 99, $1)
        }
    }

    func devices(in room: String, type: String) -> [Device] {
        devices.filter { $0.room == room && $0.type == type }
    }

    func devices(type: String) -> [Device] {
        devices.filter { $0.type == type }
    }

    func device(_ uid: String) -> Device? {
        devices.first { $0.uid == uid }
    }

    var accountID: String? { isDemo ? "demo" : CredentialStore.load()?.id }

    /// 밝기: 서버가 값을 주면 그 값, 아니면 마지막으로 설정한 값
    func brightness(of device: Device) -> Int {
        if let value = device.brightness { return value }
        let saved = UserDefaults.standard.integer(forKey: "brightness.\(device.uid)")
        return saved > 0 ? saved : 100
    }

    // MARK: - Session

    func signIn(id: String, password: String) async -> Bool {
        if isDemo { isSignedIn = true; return true }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await ElifeClient.shared.verify(id: id, password: password)
            CredentialStore.save(Credentials(id: id, password: password))
            apply(list)
            isSignedIn = true
            message = nil
            ScheduleStore.shared.updateBackgroundMode()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func signOut() {
        CredentialStore.clear()
        Task { await ElifeClient.shared.logoutNow() }
        devices = []
        lastUpdated = nil
        UserDefaults.standard.removeObject(forKey: "deviceCache")
        isSignedIn = false
        message = nil
        ScheduleStore.shared.updateBackgroundMode()
    }

    /// 앱을 열 때: 저장된 상태가 없을 때만 한 번 불러온다 (그 외엔 로그인하지 않음)
    func becameActive() {
        guard isSignedIn, !isDemo, devices.isEmpty else { return }
        Task { await refresh() }
    }

    /// 백그라운드로 갈 때: 남아 있는 로그인을 바로 정리
    func enteredBackground() {
        guard !isDemo else { return }
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "logout") {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        Task {
            await ElifeClient.shared.logoutNow()
            if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id) }
        }
    }

    func refresh(quiet: Bool = false) async {
        if isDemo { lastUpdated = Date(); return }
        guard isSignedIn else { return }
        if !quiet { isLoading = true }
        defer { if !quiet { isLoading = false } }
        do {
            apply(try await ElifeClient.shared.fetchDevices())
            message = nil
        } catch {
            handle(error)
        }
    }

    /// 단축어 · 일정이 화면 밖에서 읽어 온 최신 상태를 반영
    static func ingest(_ list: [Device]) {
        guard !list.isEmpty else { return }
        shared.apply(list)
    }

    private func apply(_ list: [Device]) {
        devices = list
        lastUpdated = Date()
        if !rooms.isEmpty && !rooms.contains(selectedRoom) {
            selectedRoom = rooms.contains(Room.defaultRoom) ? Room.defaultRoom : rooms[0]
        }
        saveCache()
    }

    private func handle(_ error: Error) {
        if let error = error as? ElifeError, error == .needsCredentials {
            isSignedIn = false
        }
        message = error.localizedDescription
    }

    // MARK: - Cache (마지막으로 확인한 상태)

    private func saveCache() {
        guard !isDemo, let data = try? JSONEncoder().encode(DeviceCache(devices: devices, updated: lastUpdated)) else { return }
        UserDefaults.standard.set(data, forKey: "deviceCache")
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: "deviceCache"),
              let cache = try? JSONDecoder().decode(DeviceCache.self, from: data) else { return }
        devices = cache.devices
        lastUpdated = cache.updated
    }

    // MARK: - Controls

    func setLight(_ device: Device, on: Bool) {
        perform(device, optimistic: ["status": on ? "on" : "off"]) {
            try await $0.controlAll(type: "light", uid: device.uid, control: on ? "on" : "off")
        }
    }

    /// 밝기 (6단계). 서버 형식 "light_000_050" — 방 3에서 실제로 바뀌는 것 확인함.
    /// 꺼져 있으면 먼저 켠다.
    func setBrightness(_ device: Device, _ value: Int) {
        let level = Device.snapBrightness(value)
        let payload = device.brightnessValue(level)
        UserDefaults.standard.set(level, forKey: "brightness.\(device.uid)")
        let wasOn = device.isOn == true
        perform(device, optimistic: ["status": "on", "value": payload]) { client in
            if !wasOn {
                try await client.controlAll(type: "light", uid: device.uid, control: "on")
            }
            try await client.control(type: "light", uid: device.uid, operation: ["value": payload])
        }
    }

    func setSocket(_ device: Device, on: Bool) {
        perform(device, optimistic: ["status": on ? "on" : "off"]) {
            try await $0.controlAll(type: "wallsocket", uid: device.uid, control: on ? "on" : "off")
        }
    }

    /// 에어컨 / 난방 / 환기 전원
    func setPower(_ device: Device, on: Bool) {
        let optimistic: [String: String] = device.status == nil ? [:] : ["status": on ? "on" : "off"]
        perform(device, optimistic: optimistic) {
            try await $0.control(type: device.type, uid: device.uid, operation: ["control": on ? "on" : "off"])
        }
    }

    func setTemperature(_ device: Device, _ value: Int) {
        perform(device, optimistic: ["set_temp": String(value)]) {
            try await $0.control(type: device.type, uid: device.uid, operation: ["set_temp": String(value)])
        }
    }

    func setAirconMode(_ device: Device, _ mode: AirconMode) {
        perform(device, optimistic: ["mode": mode.rawValue]) {
            try await $0.control(type: "aircon", uid: device.uid, operation: ["mode": mode.rawValue])
        }
    }

    func setWind(_ device: Device, _ wind: WindSpeed) {
        perform(device, optimistic: ["wind_speed": wind.rawValue]) {
            try await $0.control(type: device.type, uid: device.uid, operation: ["wind_speed": wind.rawValue])
        }
    }

    func setHeatAway(_ device: Device) {
        perform(device, optimistic: ["mode": "out"]) {
            try await $0.control(type: "heat", uid: device.uid, operation: ["mode": "out"])
        }
    }

    func closeGas(_ device: Device) {
        perform(device, optimistic: ["status": "close"]) {
            try await $0.control(type: "gas", uid: device.uid, operation: ["control": "close"])
        }
    }

    func allLightsOff() {
        for light in devices(type: "light") where light.isOn != false {
            setLight(light, on: false)
        }
    }

    private func perform(_ device: Device, optimistic: [String: String],
                         _ action: @escaping (ElifeClient) async throws -> Void) {
        let previous = self.device(device.uid)?.op
        update(device.uid) { $0.op.merge(optimistic) { _, new in new } }
        busy.insert(device.uid)
        Task {
            defer { busy.remove(device.uid) }
            do {
                if !isDemo {
                    try await action(ElifeClient.shared)
                }
                saveCache()
                scheduleVerify()
            } catch {
                if let previous { update(device.uid) { $0.op = previous } }
                handle(error)
            }
        }
    }

    private func update(_ uid: String, _ change: (inout Device) -> Void) {
        guard let index = devices.firstIndex(where: { $0.uid == uid }) else { return }
        change(&devices[index])
    }

    /// 서버 반영 확인용 재조회 — 같은 로그인 안에서 처리된 뒤 로그아웃
    private func scheduleVerify() {
        guard !isDemo else { return }
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            await self?.refresh(quiet: true)
        }
    }
}

private struct DeviceCache: Codable {
    var devices: [Device]
    var updated: Date?
}

final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
}

/// 시뮬레이터 스크린샷용 가짜 데이터 (네트워크를 전혀 쓰지 않음)
enum DemoData {
    static let devices: [Device] = [
        Device(uid: "D-L3", type: "light", name: "침실3등", room: "침실3", op: ["status": "on", "value": "light_000_067", "options": "light_999_100"]),
        Device(uid: "D-A3", type: "aircon", name: "에어컨", room: "침실3",
               op: ["status": "off", "mode": "cool", "set_temp": "26", "current_temp": "27", "wind_speed": "high"]),
        Device(uid: "D-H3", type: "heat", name: "난방", room: "침실3", op: ["set_temp": "22", "current_temp": "24"]),
        Device(uid: "D-S31", type: "wallsocket", name: "콘센트1", room: "침실3", op: ["status": "on"]),
        Device(uid: "D-S32", type: "wallsocket", name: "콘센트2", room: "침실3", op: ["status": "off"]),
        Device(uid: "D-L0", type: "light", name: "거실1등", room: "거실", op: ["status": "off"]),
        Device(uid: "D-L0b", type: "light", name: "거실2등", room: "거실", op: ["status": "on"]),
        Device(uid: "D-A0", type: "aircon", name: "에어컨", room: "거실",
               op: ["status": "off", "mode": "cool", "set_temp": "27", "current_temp": "28", "wind_speed": "low"]),
        Device(uid: "D-L1", type: "light", name: "침실1등", room: "침실1", op: ["status": "off"]),
        Device(uid: "D-L2", type: "light", name: "침실2등", room: "침실2", op: ["status": "off"]),
        Device(uid: "D-V", type: "vent", name: "환기", room: "주방", op: ["status": "off", "wind_speed": "low"]),
        Device(uid: "D-G", type: "gas", name: "가스", room: "주방", op: ["status": "close"]),
    ]
}
