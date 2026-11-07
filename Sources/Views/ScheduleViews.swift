import SwiftUI

struct ScheduleListView: View {
    @EnvironmentObject private var store: ScheduleStore
    @State private var editing: Schedule?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Group {
                if store.schedules.isEmpty {
                    ContentUnavailableView {
                        Label("일정 없음", systemImage: "clock")
                    } description: {
                        Text("정해진 시간에 불을 끄거나 에어컨을 켜도록 예약하세요.")
                    } actions: {
                        Button("일정 추가") { creating = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(store.schedules) { schedule in
                                ScheduleRow(schedule: schedule, running: store.running.contains(schedule.id)) {
                                    store.setEnabled(schedule.id, $0)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { editing = schedule }
                                .swipeActions {
                                    Button(role: .destructive) { store.delete(schedule.id) } label: {
                                        Label("삭제", systemImage: "trash")
                                    }
                                }
                            }
                        } footer: {
                            BackgroundFooter()
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("일정")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { ScheduleEditView(original: $0) }
            .sheet(isPresented: $creating) { ScheduleEditView(original: nil) }
        }
    }
}

struct ScheduleRow: View {
    let schedule: Schedule
    let running: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.timeText)
                    .font(.system(size: 40, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(schedule.enabled ? Color.primary : Color.secondary)
                HStack(spacing: 5) {
                    Image(systemName: schedule.action.symbol)
                    Text("\(Room.display(schedule.room)) · \(schedule.action.title) · \(schedule.repeatText)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let result = schedule.lastResult, let date = schedule.lastRun {
                    Text("\(date.formatted(.relative(presentation: .named))) \(result)")
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("완료") ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
            }
            Spacer()
            if running {
                ProgressView()
            } else {
                Toggle("사용", isOn: Binding(get: { schedule.enabled }, set: onToggle))
                    .labelsHidden()
            }
        }
        .padding(.vertical, 4)
    }
}

struct BackgroundFooter: View {
    @EnvironmentObject private var store: ScheduleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.backgroundEnabled {
                Label(store.isKeepingAlive ? "백그라운드에서 대기 중" : "앱을 열면 백그라운드 대기를 시작해요",
                      systemImage: store.isKeepingAlive ? "checkmark.circle" : "pause.circle")
            }
            Text("앱을 완전히 종료(위로 쓸어 올리기)하면 예약을 실행할 수 없어요. 그때는 예약 시각에 알림이 오고, 알림의 '지금 실행'으로 바로 실행할 수 있어요.")
        }
        .padding(.top, 6)
    }
}

@MainActor
struct ScheduleEditView: View {
    @EnvironmentObject private var store: ScheduleStore
    @EnvironmentObject private var home: HomeStore
    @Environment(\.dismiss) private var dismiss

    let original: Schedule?

    @State private var time = Date()
    @State private var weekdays: Set<Int> = []
    @State private var room = Room.defaultRoom
    @State private var kind: Kind = .light
    @State private var turnOn = false
    @State private var useTemp = false
    @State private var temp = 26
    @State private var loaded = false

    enum Kind: String, CaseIterable, Identifiable {
        case light, aircon, heat, sockets
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: return "조명"
            case .aircon: return "에어컨"
            case .heat: return "난방"
            case .sockets: return "콘센트"
            }
        }
        var deviceType: String {
            switch self {
            case .light: return "light"
            case .aircon: return "aircon"
            case .heat: return "heat"
            case .sockets: return "wallsocket"
            }
        }
    }

    private var rooms: [String] {
        let list = home.rooms
        return list.isEmpty ? [Room.defaultRoom] : list
    }

    private var kinds: [Kind] {
        let available = Kind.allCases.filter { !home.devices(in: room, type: $0.deviceType).isEmpty }
        return available.isEmpty ? Kind.allCases : available
    }

    private var tempRange: ClosedRange<Int> { kind == .aircon ? 18...30 : 15...30 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("시간", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                Section("반복") {
                    WeekdayPicker(selection: $weekdays)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }

                Section("동작") {
                    Picker("방", selection: $room) {
                        ForEach(rooms, id: \.self) { Text(Room.display($0)).tag($0) }
                    }
                    Picker("기기", selection: $kind) {
                        ForEach(kinds) { Text($0.title).tag($0) }
                    }
                    Picker("동작", selection: $turnOn) {
                        Text("끄기").tag(false)
                        Text("켜기").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if turnOn && (kind == .aircon || kind == .heat) {
                        Toggle("온도도 맞추기", isOn: $useTemp)
                        if useTemp {
                            Stepper(value: $temp, in: tempRange) {
                                HStack {
                                    Text("설정 온도")
                                    Spacer()
                                    Text("\(temp)°").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let original {
                    Section {
                        Button("일정 삭제", role: .destructive) {
                            store.delete(original.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(original == nil ? "새 일정" : "일정 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장", action: save).fontWeight(.semibold) }
            }
            .onAppear(perform: load)
            .onChange(of: room) { _, _ in
                if !kinds.contains(kind), let first = kinds.first { kind = first }
            }
            .onChange(of: kind) { _, newKind in
                temp = min(max(temp, tempRange.lowerBound), tempRange.upperBound)
                if newKind == .aircon && !useTemp { temp = 26 }
                if newKind == .heat && !useTemp { temp = 22 }
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let calendar = Calendar.current
        if let original {
            time = calendar.date(bySettingHour: original.hour, minute: original.minute, second: 0, of: Date()) ?? Date()
            weekdays = Set(original.weekdays)
            room = original.room
            switch original.action {
            case .light(let on): kind = .light; turnOn = on
            case .sockets(let on): kind = .sockets; turnOn = on
            case .aircon(let on, let t): kind = .aircon; turnOn = on; useTemp = t != nil; temp = t ?? 26
            case .heat(let on, let t): kind = .heat; turnOn = on; useTemp = t != nil; temp = t ?? 22
            }
        } else {
            room = rooms.contains(home.selectedRoom) ? home.selectedRoom : rooms[0]
            weekdays = Set(1...7)
            time = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()
            kind = kinds.first ?? .light
            turnOn = false
        }
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let action: ScheduleAction
        switch kind {
        case .light: action = .light(turnOn)
        case .sockets: action = .sockets(turnOn)
        case .aircon: action = .aircon(turnOn, turnOn && useTemp ? temp : nil)
        case .heat: action = .heat(turnOn, turnOn && useTemp ? temp : nil)
        }
        var schedule = original ?? Schedule(hour: 0, minute: 0, room: room, action: action)
        schedule.hour = parts.hour ?? 0
        schedule.minute = parts.minute ?? 0
        schedule.weekdays = Weekday.ordered.map(\.value).filter { weekdays.contains($0) }
        schedule.room = room
        schedule.action = action
        schedule.enabled = true
        store.upsert(schedule)
        dismiss()
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Weekday.ordered) { day in
                    let selected = selection.contains(day.value)
                    Button {
                        if selected { selection.remove(day.value) } else { selection.insert(day.value) }
                    } label: {
                        Text(day.short)
                            .font(.subheadline.weight(.medium))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(selected ? Color.accentColor : Color(.tertiarySystemFill)))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var summary: String {
        if selection.isEmpty { return "한 번만 실행" }
        if selection.count == 7 { return "매일" }
        if selection == [2, 3, 4, 5, 6] { return "주중마다" }
        if selection == [1, 7] { return "주말마다" }
        return Weekday.ordered.filter { selection.contains($0.value) }.map(\.short).joined(separator: ", ") + "요일마다"
    }
}

struct SettingsView: View {
    @EnvironmentObject private var home: HomeStore
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("계정") {
                    LabeledContent("아이디", value: home.accountID ?? "—")
                    Button("로그아웃", role: .destructive) { confirmSignOut = true }
                }

                Section {
                    Picker("기본 방", selection: $home.selectedRoom) {
                        ForEach(home.rooms.isEmpty ? [Room.defaultRoom] : home.rooms, id: \.self) {
                            Text(Room.display($0)).tag($0)
                        }
                    }
                }

                Section {
                    Toggle("백그라운드에서 일정 실행", isOn: $store.backgroundEnabled)
                    Toggle("일정 실행 시 자동 로그인", isOn: $store.autoLogin)
                    Toggle("실행 결과 알림", isOn: $store.notifyOnRun)
                } header: {
                    Text("일정")
                } footer: {
                    Text("일정이 있으면 무음 오디오로 앱을 깨워 둡니다. 음악 재생에는 영향이 없어요. 세션이 만료된 상태에서 일정이 실행되면 저장된 계정으로 다시 로그인하며, 이때 공식 Smart eLife 앱은 로그아웃됩니다.")
                }

                Section {
                    LabeledContent("버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    LabeledContent("서버", value: "smartelife.apt.co.kr")
                } footer: {
                    Text("별도 서버 없이 이 iPhone이 아파트 서버와 직접 통신합니다.")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() }.fontWeight(.semibold) }
            }
            .confirmationDialog("로그아웃할까요?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("로그아웃", role: .destructive) {
                    home.signOut()
                    dismiss()
                }
            } message: {
                Text("저장된 계정 정보가 이 기기에서 삭제되고 일정도 실행되지 않아요.")
            }
        }
    }
}
