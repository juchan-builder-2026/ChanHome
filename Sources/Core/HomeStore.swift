import Foundation
import SwiftUI

/// 화면 상태 + 기기 제어. 모든 제어는 사용자가 누른 그 동작만 그대로 보낸다.
/// 제어 후에는 서버에서 상태를 다시 읽어 실제로 반영된 값만 보여준다.
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
    private var pollTask: Task<Void, Never>?
    private var verifyTask: Task<Void, Never>?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        isDemo = arguments.contains("-demo")
        selectedRoom = UserDefaults.standard.string(forKey: "selectedRoom") ?? Room.defaultRoom
        if isDemo {
            isSignedIn = !arguments.contains("-demoLogin")
            devices = DemoData.devices
            lastUpdated = Date()
            selectedRoom = Room.defaultRoom
        } else {
            isSignedIn = CredentialStore.load() != nil
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

    // MARK: - Session

    func signIn(id: String, password: String) async -> Bool {
        if isDemo { isSignedIn = true; return true }
        isLoading = true
        defer { isLoading = false }
        do {
            try await ElifeClient.shared.login(id: id, password: password)
            CredentialStore.save(Credentials(id: id, password: password))
            isSignedIn = true
            message = nil
            await refresh(quiet: true)
            ScheduleStore.shared.updateBackgroundMode()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func signOut() {
        CredentialStore.clear()
        Task { await ElifeClient.shared.reset() }
        devices = []
        isSignedIn = false
        message = nil
        stopPolling()
        ScheduleStore.shared.updateBackgroundMode()
    }

    func becameActive() {
        guard isSignedIn else { return }
        Task { await refresh(quiet: devices.isEmpty == false) }
        startPolling()
    }

    func enteredBackground() {
        stopPolling()
    }

    func refresh(quiet: Bool = false) async {
        if isDemo { lastUpdated = Date(); return }
        guard isSignedIn else { return }
        if !quiet { isLoading = true }
        defer { if !quiet { isLoading = false } }
        do {
            devices = try await ElifeClient.shared.fetchDevices(allowLogin: true)
            lastUpdated = Date()
            message = nil
            if !rooms.isEmpty && !rooms.contains(selectedRoom) {
                selectedRoom = rooms.contains(Room.defaultRoom) ? Room.defaultRoom : rooms[0]
            }
        } catch {
            handle(error)
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await self?.refresh(quiet: true)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func handle(_ error: Error) {
        if let error = error as? ElifeError, error == .needsCredentials {
            isSignedIn = false
        }
        message = error.localizedDescription
    }

    // MARK: - Controls

    func setLight(_ device: Device, on: Bool) {
        perform(device, optimistic: ["status": on ? "on" : "off"]) {
            try await $0.controlAll(type: "light", uid: device.uid, control: on ? "on" : "off", allowLogin: true)
        }
    }

    func setSocket(_ device: Device, on: Bool) {
        perform(device, optimistic: ["status": on ? "on" : "off"]) {
            try await $0.controlAll(type: "wallsocket", uid: device.uid, control: on ? "on" : "off", allowLogin: true)
        }
    }

    /// 에어컨 / 난방 / 환기 전원
    func setPower(_ device: Device, on: Bool) {
        let optimistic: [String: String] = device.status == nil ? [:] : ["status": on ? "on" : "off"]
        perform(device, optimistic: optimistic) {
            try await $0.control(type: device.type, uid: device.uid, operation: ["control": on ? "on" : "off"], allowLogin: true)
        }
    }

    func setTemperature(_ device: Device, _ value: Int) {
        perform(device, optimistic: ["set_temp": String(value)]) {
            try await $0.control(type: device.type, uid: device.uid, operation: ["set_temp": String(value)], allowLogin: true)
        }
    }

    func setAirconMode(_ device: Device, _ mode: AirconMode) {
        perform(device, optimistic: ["mode": mode.rawValue]) {
            try await $0.control(type: "aircon", uid: device.uid, operation: ["mode": mode.rawValue], allowLogin: true)
        }
    }

    func setWind(_ device: Device, _ wind: WindSpeed) {
        perform(device, optimistic: ["wind_speed": wind.rawValue]) {
            try await $0.control(type: device.type, uid: device.uid, operation: ["wind_speed": wind.rawValue], allowLogin: true)
        }
    }

    func setHeatAway(_ device: Device) {
        perform(device, optimistic: ["mode": "out"]) {
            try await $0.control(type: "heat", uid: device.uid, operation: ["mode": "out"], allowLogin: true)
        }
    }

    func closeGas(_ device: Device) {
        perform(device, optimistic: ["status": "close"]) {
            try await $0.control(type: "gas", uid: device.uid, operation: ["control": "close"], allowLogin: true)
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

    /// 서버 반영 확인용 재조회 (연속 조작은 하나로 묶음)
    private func scheduleVerify() {
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            await self?.refresh(quiet: true)
        }
    }
}

/// 시뮬레이터 스크린샷용 가짜 데이터 (네트워크를 전혀 쓰지 않음)
enum DemoData {
    static let devices: [Device] = [
        Device(uid: "D-L3", type: "light", name: "침실3등", room: "침실3", op: ["status": "on", "location_name": "침실3"]),
        Device(uid: "D-A3", type: "aircon", name: "에어컨", room: "침실3",
               op: ["status": "off", "mode": "cool", "set_temp": "26", "current_temp": "27", "wind_speed": "high"]),
        Device(uid: "D-H3", type: "heat", name: "난방", room: "침실3", op: ["set_temp": "22", "current_temp": "24"]),
        Device(uid: "D-S31", type: "wallsocket", name: "콘센트1", room: "침실3", op: ["status": "on"]),
        Device(uid: "D-S32", type: "wallsocket", name: "콘센트2", room: "침실3", op: ["status": "off"]),
        Device(uid: "D-L0", type: "light", name: "거실1등", room: "거실", op: ["status": "off"]),
        Device(uid: "D-A0", type: "aircon", name: "에어컨", room: "거실",
               op: ["status": "off", "mode": "cool", "set_temp": "27", "current_temp": "28", "wind_speed": "low"]),
        Device(uid: "D-L1", type: "light", name: "침실1등", room: "침실1", op: ["status": "off"]),
        Device(uid: "D-L2", type: "light", name: "침실2등", room: "침실2", op: ["status": "off"]),
        Device(uid: "D-V", type: "vent", name: "환기", room: "주방", op: ["status": "off", "wind_speed": "low"]),
        Device(uid: "D-G", type: "gas", name: "가스", room: "주방", op: ["status": "close"]),
    ]
}
