import AppIntents

// MARK: - 선택지

enum RoomOption: String, AppEnum {
    case room3 = "침실3"
    case living = "거실"
    case room1 = "침실1"
    case room2 = "침실2"

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "방" }
    static var caseDisplayRepresentations: [RoomOption: DisplayRepresentation] {
        [
            .room3: DisplayRepresentation(title: "방 3", synonyms: ["방3", "내 방", "내방", "침실 3", "작은방"]),
            .living: DisplayRepresentation(title: "거실", synonyms: ["리빙룸"]),
            .room1: DisplayRepresentation(title: "방 1", synonyms: ["방1", "침실 1", "안방"]),
            .room2: DisplayRepresentation(title: "방 2", synonyms: ["방2", "침실 2"]),
        ]
    }
}

enum ToggleOption: String, AppEnum {
    case toggle, on, off

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "동작" }
    static var caseDisplayRepresentations: [ToggleOption: DisplayRepresentation] {
        [
            .toggle: DisplayRepresentation(title: "전환", synonyms: ["토글", "반대로", "바꿔"]),
            .on: DisplayRepresentation(title: "켜기", synonyms: ["켜", "켜줘", "on"]),
            .off: DisplayRepresentation(title: "끄기", synonyms: ["꺼", "꺼줘", "off"]),
        ]
    }

    var mode: PowerMode {
        switch self {
        case .toggle: return .toggle
        case .on: return .on
        case .off: return .off
        }
    }
}

enum OnOffOption: String, AppEnum {
    case on, off

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "전원" }
    static var caseDisplayRepresentations: [OnOffOption: DisplayRepresentation] {
        [
            .on: DisplayRepresentation(title: "켜기", synonyms: ["켜", "켜줘", "on"]),
            .off: DisplayRepresentation(title: "끄기", synonyms: ["꺼", "꺼줘", "off"]),
        ]
    }

    var isOn: Bool { self == .on }
}

/// 실측상 조명은 6단계로 맞춰진다
enum BrightnessOption: String, AppEnum {
    case p17 = "17", p33 = "33", p50 = "50", p67 = "67", p83 = "83", p100 = "100"

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "밝기" }
    static var caseDisplayRepresentations: [BrightnessOption: DisplayRepresentation] {
        [
            .p17: DisplayRepresentation(title: "17%", synonyms: ["최소", "가장 어둡게", "1단계"]),
            .p33: DisplayRepresentation(title: "33%", synonyms: ["2단계", "어둡게"]),
            .p50: DisplayRepresentation(title: "50%", synonyms: ["중간", "반", "3단계"]),
            .p67: DisplayRepresentation(title: "67%", synonyms: ["4단계"]),
            .p83: DisplayRepresentation(title: "83%", synonyms: ["5단계", "밝게"]),
            .p100: DisplayRepresentation(title: "100%", synonyms: ["최대", "가장 밝게", "6단계"]),
        ]
    }

    var level: Int { Int(rawValue) ?? 100 }
}

// MARK: - 조명

struct LightPowerIntent: AppIntent {
    static var title: LocalizedStringResource { "조명 켜기/끄기" }
    static var description: IntentDescription { IntentDescription("방의 조명을 켜거나, 끄거나, 반대로 바꿉니다. 동작 버튼에는 '전환'을 추천해요.") }

    @Parameter(title: "방", default: .room3)
    var room: RoomOption

    @Parameter(title: "동작", default: .toggle)
    var action: ToggleOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$room) 조명 \(\.$action)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let room = self.room.rawValue, mode = action.mode
        let message = try await BackgroundRunner.run { try await HomeActions.lights(room: room, mode: mode) }
        return .result(value: message, dialog: "\(message)")
    }
}

struct LightBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource { "조명 밝기 설정" }
    static var description: IntentDescription { IntentDescription("조명 밝기를 6단계 중 하나로 맞춥니다. 꺼져 있으면 켜고 맞춰요.") }

    @Parameter(title: "방", default: .room3)
    var room: RoomOption

    @Parameter(title: "밝기", default: .p50)
    var brightness: BrightnessOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$room) 조명 밝기를 \(\.$brightness)로")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let room = self.room.rawValue, level = brightness.level
        let message = try await BackgroundRunner.run { try await HomeActions.brightness(room: room, level: level) }
        return .result(value: message, dialog: "\(message)")
    }
}

struct AllLightsOffIntent: AppIntent {
    static var title: LocalizedStringResource { "모든 조명 끄기" }
    static var description: IntentDescription { IntentDescription("집 안에서 켜져 있는 조명을 모두 끕니다.") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await BackgroundRunner.run { try await HomeActions.allLightsOff() }
        return .result(value: message, dialog: "\(message)")
    }
}

// MARK: - 냉난방

struct AirconIntent: AppIntent {
    static var title: LocalizedStringResource { "에어컨 켜기/끄기" }
    static var description: IntentDescription { IntentDescription("에어컨을 켜거나 끕니다. 켤 때 온도(18~30°)를 함께 지정할 수 있어요.") }

    @Parameter(title: "방", default: .room3)
    var room: RoomOption

    @Parameter(title: "전원", default: .on)
    var power: OnOffOption

    @Parameter(title: "온도(°C)", description: "비워 두면 기존 설정 온도 그대로")
    var temperature: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$room) 에어컨 \(\.$power)") {
            \.$temperature
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let room = self.room.rawValue, on = power.isOn, temp = temperature
        let message = try await BackgroundRunner.run { try await HomeActions.aircon(room: room, on: on, temperature: temp) }
        return .result(value: message, dialog: "\(message)")
    }
}

struct HeatIntent: AppIntent {
    static var title: LocalizedStringResource { "난방 켜기/끄기" }
    static var description: IntentDescription { IntentDescription("난방을 켜거나 끕니다. 켤 때 온도(15~30°)를 함께 지정할 수 있어요.") }

    @Parameter(title: "방", default: .room3)
    var room: RoomOption

    @Parameter(title: "전원", default: .on)
    var power: OnOffOption

    @Parameter(title: "온도(°C)", description: "비워 두면 기존 설정 온도 그대로")
    var temperature: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$room) 난방 \(\.$power)") {
            \.$temperature
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let room = self.room.rawValue, on = power.isOn, temp = temperature
        let message = try await BackgroundRunner.run { try await HomeActions.heat(room: room, on: on, temperature: temp) }
        return .result(value: message, dialog: "\(message)")
    }
}

// MARK: - 기타

struct SocketsIntent: AppIntent {
    static var title: LocalizedStringResource { "콘센트 켜기/끄기" }
    static var description: IntentDescription { IntentDescription("방의 콘센트를 모두 켜거나 끕니다.") }

    @Parameter(title: "방", default: .room3)
    var room: RoomOption

    @Parameter(title: "전원", default: .off)
    var power: OnOffOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$room) 콘센트 \(\.$power)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let room = self.room.rawValue, on = power.isOn
        let message = try await BackgroundRunner.run { try await HomeActions.sockets(room: room, on: on) }
        return .result(value: message, dialog: "\(message)")
    }
}

struct VentIntent: AppIntent {
    static var title: LocalizedStringResource { "환기 켜기/끄기" }
    static var description: IntentDescription { IntentDescription("환기 장치를 켜거나 끕니다.") }

    @Parameter(title: "전원", default: .on)
    var power: OnOffOption

    static var parameterSummary: some ParameterSummary {
        Summary("환기 \(\.$power)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let on = power.isOn
        let message = try await BackgroundRunner.run { try await HomeActions.vent(on: on) }
        return .result(value: message, dialog: "\(message)")
    }
}

struct GasLockIntent: AppIntent {
    static var title: LocalizedStringResource { "가스 밸브 잠그기" }
    static var description: IntentDescription { IntentDescription("가스 밸브를 잠급니다. (원격으로 여는 기능은 없어요)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await BackgroundRunner.run { try await HomeActions.closeGas() }
        return .result(value: message, dialog: "\(message)")
    }
}

struct HomeStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "방 상태 확인" }
    static var description: IntentDescription { IntentDescription("방의 조명·에어컨·난방·콘센트 상태를 문장으로 알려줍니다. 결과를 다른 단축어 동작에 넘길 수 있어요.") }

    @Parameter(title: "방", default: .room3)
    var room: RoomOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$room) 상태 확인")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let room = self.room.rawValue
        let message = try await BackgroundRunner.run { try await HomeActions.status(room: room) }
        return .result(value: message, dialog: "\(message)")
    }
}

// MARK: - Siri / 동작 버튼 / Spotlight 에 바로 뜨는 단축어

struct ChanHomeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LightPowerIntent(),
            phrases: [
                "\(.applicationName) 불 \(\.$action)",
                "\(.applicationName) 조명 \(\.$action)",
                "\(.applicationName) \(\.$room) 불",
                "\(.applicationName) \(\.$room) 조명",
                "\(.applicationName) 불",
            ],
            shortTitle: "조명 켜기/끄기",
            systemImageName: "lightbulb.fill"
        )
        AppShortcut(
            intent: LightBrightnessIntent(),
            phrases: [
                "\(.applicationName) 밝기 \(\.$brightness)",
                "\(.applicationName)에서 밝기 \(\.$brightness)로",
            ],
            shortTitle: "조명 밝기",
            systemImageName: "sun.max.fill"
        )
        AppShortcut(
            intent: AllLightsOffIntent(),
            phrases: [
                "\(.applicationName) 모든 불 꺼",
                "\(.applicationName) 전체 소등",
                "\(.applicationName) 불 다 꺼",
            ],
            shortTitle: "모든 조명 끄기",
            systemImageName: "lightbulb.slash"
        )
        AppShortcut(
            intent: AirconIntent(),
            phrases: [
                "\(.applicationName) 에어컨 \(\.$power)",
            ],
            shortTitle: "에어컨",
            systemImageName: "snowflake"
        )
        AppShortcut(
            intent: HeatIntent(),
            phrases: [
                "\(.applicationName) 난방 \(\.$power)",
                "\(.applicationName) 보일러 \(\.$power)",
            ],
            shortTitle: "난방",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: HomeStatusIntent(),
            phrases: [
                "\(.applicationName) \(\.$room) 상태",
                "\(.applicationName) 상태 알려줘",
                "\(.applicationName) 상태",
            ],
            shortTitle: "방 상태",
            systemImageName: "house"
        )
        // 콘센트 · 환기는 단축어 앱의 동작으로만 (앱 단축어는 최대 10개)
        AppShortcut(
            intent: SleepIntent(),
            phrases: [
                "\(.applicationName) 잘게",
                "\(.applicationName) 잘 자",
                "\(.applicationName) 취침",
                "\(.applicationName) \(\.$duration) 동안 불 꺼",
            ],
            shortTitle: "취침 모드",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: SkipNextWakeIntent(),
            phrases: [
                "\(.applicationName) 알람 꺼",
                "\(.applicationName) 내일 알람 꺼",
                "\(.applicationName) 알람 건너뛰기",
            ],
            shortTitle: "다음 알람 건너뛰기",
            systemImageName: "alarm.waves.left.and.right"
        )
        AppShortcut(
            intent: WakeStatusIntent(),
            phrases: [
                "\(.applicationName) 알람 몇 시",
                "\(.applicationName) 알람 언제",
            ],
            shortTitle: "다음 알람",
            systemImageName: "alarm.fill"
        )
        AppShortcut(
            intent: GasLockIntent(),
            phrases: [
                "\(.applicationName) 가스 잠가",
                "\(.applicationName) 가스 밸브 잠가",
            ],
            shortTitle: "가스 잠그기",
            systemImageName: "flame"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .orange }
}
