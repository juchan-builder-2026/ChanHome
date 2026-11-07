import SwiftUI

@MainActor
struct ClimateSheet: View {
    @EnvironmentObject private var home: HomeStore
    @Environment(\.dismiss) private var dismiss
    let uid: String

    @State private var target = 0
    @State private var sendTask: Task<Void, Never>?

    private var device: Device? { home.device(uid) }

    var body: some View {
        NavigationStack {
            Group {
                if let device {
                    content(device)
                } else {
                    ContentUnavailableView("기기를 찾을 수 없어요", systemImage: "questionmark")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(device.map { "\(Room.display($0.room)) \($0.displayName)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if let device {
                target = device.setTemp ?? (device.type == "aircon" ? 26 : 22)
            }
        }
    }

    private func range(for device: Device) -> ClosedRange<Int> {
        device.type == "aircon" ? 18...30 : 15...30
    }

    @ViewBuilder
    private func content(_ device: Device) -> some View {
        let isAircon = device.type == "aircon"
        let tint: Color = isAircon ? .blue : .orange
        ScrollView {
            VStack(spacing: 22) {
                PowerCard(device: device, tint: tint, busy: home.busy.contains(device.uid)) { on in
                    home.setPower(device, on: on)
                }

                VStack(spacing: 4) {
                    Text("\(target)°")
                        .font(.system(size: 96, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(target)))
                        .animation(.snappy, value: target)
                    Text(device.currentTemp.map { "현재 \($0)°" } ?? "설정 온도")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 48) {
                        RoundButton(symbol: "minus") { change(-1, device) }
                            .disabled(target <= range(for: device).lowerBound)
                        RoundButton(symbol: "plus") { change(+1, device) }
                            .disabled(target >= range(for: device).upperBound)
                    }
                    .padding(.top, 14)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(CardBackground())
                .sensoryFeedback(.selection, trigger: target)

                if isAircon {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("모드").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("모드", selection: Binding(
                            get: { AirconMode(rawValue: device.mode ?? "") ?? .cool },
                            set: { home.setAirconMode(device, $0) })) {
                            ForEach(AirconMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        Text("바람").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Picker("바람", selection: Binding(
                            get: { WindSpeed(rawValue: device.wind ?? "") ?? .auto },
                            set: { home.setWind(device, $0) })) {
                            ForEach(WindSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    .card()
                } else {
                    Button { home.setHeatAway(device) } label: {
                        HStack {
                            Image(systemName: "figure.walk.departure")
                            Text("외출 모드")
                            Spacer()
                            if device.mode == "out" { Image(systemName: "checkmark").foregroundStyle(tint) }
                        }
                        .foregroundStyle(.primary)
                        .card()
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(16)
        }
    }

    /// 버튼을 연달아 눌러도 마지막 값 하나만 보낸다
    private func change(_ delta: Int, _ device: Device) {
        let bounds = range(for: device)
        let value = min(max(target + delta, bounds.lowerBound), bounds.upperBound)
        guard value != target else { return }
        target = value
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            if let latest = home.device(uid), latest.setTemp != value {
                home.setTemperature(latest, value)
            }
        }
    }
}

struct PowerCard: View {
    let device: Device
    let tint: Color
    let busy: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: "power", tint: tint, active: device.isOn == true, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("전원").font(.headline)
                Text(stateText).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().padding(.trailing, 4) }
            if let isOn = device.isOn {
                Toggle("전원", isOn: Binding(get: { isOn }, set: onChange))
                    .labelsHidden()
                    .tint(tint)
            } else {
                HStack(spacing: 8) {
                    Button("끄기") { onChange(false) }.buttonStyle(.bordered)
                    Button("켜기") { onChange(true) }.buttonStyle(.borderedProminent).tint(tint)
                }
            }
        }
        .card()
    }

    private var stateText: String {
        switch device.isOn {
        case .some(true): return "켜짐"
        case .some(false): return "꺼짐"
        case .none: return device.mode == "out" ? "외출" : "켜기/끄기"
        }
    }
}
