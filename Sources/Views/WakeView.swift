import SwiftUI

struct WakeView: View {
    @EnvironmentObject private var wake: WakeEngine
    @State private var editing: WakeAlarm?
    @State private var creating = false
    @State private var sleepMinutes = 15

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let running = wake.running {
                        RunningCard(ramp: running, now: wake.now) { wake.cancelRunning() }
                    }

                    if let next = wake.nextUp {
                        NextAlarmCard(alarm: next.alarm, wake: next.wake, now: wake.now,
                                      onEdit: { editing = next.alarm },
                                      onSkip: { wake.toggleSkip(next.alarm.id) },
                                      onTest: { wake.startTest(next.alarm) })
                    } else if wake.alarms.isEmpty {
                        EmptyWakeCard { creating = true }
                    }

                    if !wake.alarms.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("알람")
                            VStack(spacing: 0) {
                                ForEach(Array(wake.alarms.enumerated()), id: \.element.id) { index, alarm in
                                    if index > 0 { Divider().padding(.leading, 16) }
                                    WakeRow(alarm: alarm) { wake.setEnabled(alarm.id, $0) }
                                        .contentShape(Rectangle())
                                        .onTapGesture { editing = alarm }
                                }
                            }
                            .background(CardBackground())
                        }
                    }

                    SleepCard(minutes: $sleepMinutes, running: wake.running?.kind == .sleep) {
                        _ = wake.startSleep(minutes: sleepMinutes)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label(wake.permissionText.isEmpty ? SystemAlarms.permissionText() : wake.permissionText,
                              systemImage: "bell.badge")
                        Label("조명은 앱이 백그라운드에서 대기 중일 때 밝아져요. 앱을 완전히 종료해도 알람 소리는 울리고, [끄기]를 누르면 조명이 바로 켜져요.",
                              systemImage: "info.circle")
                        if let message = wake.lastMessage {
                            Label(message, systemImage: "lightbulb")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("기상")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { WakeEditView(original: $0) }
            .sheet(isPresented: $creating) { WakeEditView(original: nil) }
        }
    }
}

// MARK: - Cards

private struct NextAlarmCard: View {
    let alarm: WakeAlarm
    let wake: Date
    let now: Date
    let onEdit: () -> Void
    let onSkip: () -> Void
    let onTest: () -> Void

    var body: some View {
        let plan = alarm.plan(for: wake)
        let start = plan.first?.at ?? wake
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(WakeFormat.dayLabel(wake, now: now)) · \(WakeFormat.remaining(until: wake, now: now))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(WakeFormat.time(wake))
                        .font(.system(size: 64, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("\(WakeFormat.shortTime(start))부터 \(alarm.rampMinutes)분 동안 \(Room.display(alarm.room)) 조명이 밝아져요")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            RampChart(plan: plan, now: now)

            HStack(spacing: 8) {
                Chip(symbol: "sun.max.fill", text: "\(alarm.finalLevel)%")
                Chip(symbol: alarm.sound ? "bell.fill" : "bell.slash", text: alarm.sound ? "소리" : "빛만")
                if alarm.sound && alarm.snoozeEnabled {
                    Chip(symbol: "moon.zzz.fill", text: "\(alarm.snoozeMinutes)분")
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button(action: onTest) {
                    Label("30초 미리보기", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: onSkip) {
                    Label("이번만 건너뛰기", systemImage: "forward.end")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
            .font(.subheadline.weight(.medium))
        }
        .card(padding: 20)
    }
}

/// 단계별 밝기 막대 그래프 (지난 단계는 진하게)
struct RampChart: View {
    let plan: [RampStep]
    let now: Date

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(plan.enumerated()), id: \.offset) { _, step in
                let level = step.level ?? 0
                let done = step.at <= now
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.yellow.opacity(done ? 1 : 0.25 + 0.6 * Double(level) / 100))
                        .frame(height: max(8, 64 * CGFloat(level) / 100))
                    Text(WakeFormat.shortTime(step.at))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 88, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("밝기 단계 \(plan.compactMap(\.level).map { "\($0)%" }.joined(separator: ", "))")
    }
}

private struct Chip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
            .foregroundStyle(.secondary)
    }
}

private struct EmptyWakeCard: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sunrise.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("빛으로 깨우는 알람")
                .font(.title3.weight(.semibold))
            Text("일어날 시간 전부터 방 조명이 해 뜨듯 천천히 밝아지고, 시간이 되면 알람이 울려요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("기상 알람 만들기", action: onCreate)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 24)
    }
}

private struct WakeRow: View {
    let alarm: WakeAlarm
    let onToggle: (Bool) -> Void

    private var repeatText: String {
        let set = Set(alarm.weekdays)
        if set.isEmpty { return "한 번" }
        if set.count == 7 { return "매일" }
        if set == [2, 3, 4, 5, 6] { return "주중" }
        if set == [1, 7] { return "주말" }
        return Weekday.ordered.filter { set.contains($0.value) }.map(\.short).joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.timeText)
                    .font(.system(size: 34, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(alarm.enabled ? Color.primary : Color.secondary)
                Text("\(repeatText) · \(alarm.rampMinutes)분 동안 \(alarm.finalLevel)%까지" + (alarm.skipDate != nil ? " · 다음 한 번 건너뜀" : ""))
                    .font(.footnote)
                    .foregroundStyle(alarm.skipDate != nil ? Color.orange : Color.secondary)
                if let result = alarm.lastResult {
                    Text(result).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("사용", isOn: Binding(get: { alarm.enabled }, set: onToggle))
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SleepCard: View {
    @Binding var minutes: Int
    let running: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconBadge(symbol: "moon.zzz.fill", tint: .indigo, active: true, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("취침 모드").font(.headline)
                    Text("지금 밝기에서 한 단계씩 낮추다가 꺼져요")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("시간", selection: $minutes) {
                Text("5분").tag(5)
                Text("10분").tag(10)
                Text("15분").tag(15)
                Text("30분").tag(30)
            }
            .pickerStyle(.segmented)
            Button(action: onStart) {
                Text(running ? "다시 시작" : "잘게요")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .card(padding: 18)
    }
}

private struct RunningCard: View {
    let ramp: RunningRamp
    let now: Date
    let onCancel: () -> Void

    var body: some View {
        let next = ramp.steps.first { $0.at > now }
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color(.tertiarySystemFill), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: ramp.progress(at: now))
                    .stroke(ramp.kind == .sleep ? Color.indigo : Color.yellow, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: ramp.kind == .sleep ? "moon.fill" : "sun.max.fill")
                    .foregroundStyle(ramp.kind == .sleep ? Color.indigo : Color.orange)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(ramp.title).font(.headline)
                if let next {
                    Text("\(WakeFormat.shortTime(next.at)) → " + (next.level.map { "\($0)%" } ?? "끄기"))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("마무리 중").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("멈춤", action: onCancel)
                .buttonStyle(.bordered)
        }
        .card()
    }
}

// MARK: - Edit

@MainActor
struct WakeEditView: View {
    @EnvironmentObject private var wake: WakeEngine
    @EnvironmentObject private var home: HomeStore
    @Environment(\.dismiss) private var dismiss
    let original: WakeAlarm?

    @State private var draft = WakeAlarm()
    @State private var time = Date()
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var loaded = false

    private var rooms: [String] {
        let lit = home.rooms.filter { !home.devices(in: $0, type: "light").isEmpty }
        return lit.isEmpty ? [Room.defaultRoom] : lit
    }

    private var previewPlan: [RampStep] {
        var copy = draft
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        copy.hour = parts.hour ?? 7
        copy.minute = parts.minute ?? 0
        let today = Calendar.current.date(bySettingHour: copy.hour, minute: copy.minute, second: 0, of: Date()) ?? Date()
        return copy.plan(for: today)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("일어날 시간", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                Section("반복") {
                    WeekdayPicker(selection: $weekdays)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }

                Section {
                    Picker("방", selection: $draft.room) {
                        ForEach(rooms, id: \.self) { Text(Room.display($0)).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("밝아지는 시간").font(.subheadline)
                        Picker("밝아지는 시간", selection: $draft.rampMinutes) {
                            Text("10분").tag(10)
                            Text("15분").tag(15)
                            Text("20분").tag(20)
                            Text("30분").tag(30)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("마지막 밝기").font(.subheadline)
                        Picker("마지막 밝기", selection: $draft.finalLevel) {
                            Text("50%").tag(50)
                            Text("67%").tag(67)
                            Text("83%").tag(83)
                            Text("100%").tag(100)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)
                    RampChart(plan: previewPlan, now: .distantPast)
                        .padding(.vertical, 6)
                } header: {
                    Text("조명")
                } footer: {
                    Text("조명은 6단계(17 · 33 · 50 · 67 · 83 · 100%)로 바뀌어요. 꺼진 조명을 켤 때는 낮은 밝기부터 켜서 번쩍이지 않아요.")
                }

                Section {
                    Toggle("소리로도 깨우기", isOn: $draft.sound)
                    if draft.sound {
                        Toggle("다시 알림", isOn: $draft.snoozeEnabled)
                        if draft.snoozeEnabled {
                            Picker("다시 알림 간격", selection: $draft.snoozeMinutes) {
                                Text("5분").tag(5)
                                Text("9분").tag(9)
                                Text("10분").tag(10)
                                Text("15분").tag(15)
                            }
                        }
                    }
                } header: {
                    Text("소리")
                } footer: {
                    Text(draft.sound
                         ? "기상 시각에 시계 앱 알람처럼 울려요. [끄기]를 누르면 조명이 마지막 밝기로 켜지고, [다시 알림]을 누르면 조명이 33%로 낮아졌다가 다시 밝아져요."
                         : "소리 없이 빛으로만 깨워요.")
                }

                if let original {
                    Section {
                        Button("알람 삭제", role: .destructive) {
                            wake.delete(original.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(original == nil ? "새 기상 알람" : "기상 알람 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장", action: save).fontWeight(.semibold) }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let original {
            draft = original
            weekdays = Set(original.weekdays)
        } else {
            draft = WakeAlarm()
            draft.room = rooms.contains(Room.defaultRoom) ? Room.defaultRoom : rooms[0]
        }
        time = Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date()
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        draft.hour = parts.hour ?? 7
        draft.minute = parts.minute ?? 0
        draft.weekdays = Weekday.ordered.map(\.value).filter { weekdays.contains($0) }
        draft.enabled = true
        wake.upsert(draft)
        dismiss()
    }
}
