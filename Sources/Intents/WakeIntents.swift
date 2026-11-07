import AppIntents

// MARK: - 알람 화면의 버튼 (AlarmKit 이 앱을 백그라운드로 깨워 실행)

struct WakeStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "기상 알람 끄기" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "기상 알람")
    var wakeID: String

    @Parameter(title: "시스템 알람")
    var alarmID: String

    init() {
        wakeID = ""
        alarmID = ""
    }

    init(wakeID: String, alarmID: String) {
        self.wakeID = wakeID
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        await WakeEngine.handleStop(wakeID: wakeID, alarmID: alarmID)
        return .result()
    }
}

struct WakeSnoozeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "기상 알람 다시 알림" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "기상 알람")
    var wakeID: String

    @Parameter(title: "시스템 알람")
    var alarmID: String

    init() {
        wakeID = ""
        alarmID = ""
    }

    init(wakeID: String, alarmID: String) {
        self.wakeID = wakeID
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        await WakeEngine.handleSnooze(wakeID: wakeID, alarmID: alarmID)
        return .result()
    }
}

// MARK: - 단축어 · Siri

enum SleepDurationOption: String, AppEnum {
    case m5 = "5", m10 = "10", m15 = "15", m30 = "30"

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "시간" }
    static var caseDisplayRepresentations: [SleepDurationOption: DisplayRepresentation] {
        [
            .m5: DisplayRepresentation(title: "5분"),
            .m10: DisplayRepresentation(title: "10분"),
            .m15: DisplayRepresentation(title: "15분"),
            .m30: DisplayRepresentation(title: "30분"),
        ]
    }

    var minutes: Int { Int(rawValue) ?? 15 }
}

struct SleepIntent: AppIntent {
    static var title: LocalizedStringResource { "취침 모드" }
    static var description: IntentDescription { IntentDescription("방 3 조명을 지금 밝기에서 한 단계씩 낮추다가 끕니다.") }

    @Parameter(title: "시간", default: .m15)
    var duration: SleepDurationOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$duration) 동안 서서히 끄기")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = await WakeEngine.sleepFromIntent(minutes: duration.minutes)
        return .result(value: message, dialog: "\(message)")
    }
}

struct SkipNextWakeIntent: AppIntent {
    static var title: LocalizedStringResource { "다음 기상 알람 건너뛰기" }
    static var description: IntentDescription { IntentDescription("다음 기상 알람 한 번만 울리지 않고 조명도 켜지 않습니다. 다시 실행하면 취소돼요.") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = await WakeEngine.skipNextFromIntent()
        return .result(value: message, dialog: "\(message)")
    }
}

struct WakeStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "다음 기상 알람" }
    static var description: IntentDescription { IntentDescription("다음 기상 알람 시각과 조명이 밝아지기 시작하는 시각을 알려줍니다.") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = await WakeEngine.statusText()
        return .result(value: message, dialog: "\(message)")
    }
}
