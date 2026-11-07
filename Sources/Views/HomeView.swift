import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var home: HomeStore
    @State private var climateUID: String?
    @State private var showSettings = false
    @State private var confirmAllOff = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    RoomPicker(rooms: home.rooms, selection: $home.selectedRoom)

                    if let message = home.message {
                        StatusBanner(text: message) { home.message = nil }
                    }

                    let room = home.selectedRoom
                    let lights = home.devices(in: room, type: "light")
                    let climate = home.devices(in: room, type: "aircon") + home.devices(in: room, type: "heat")
                    let sockets = home.devices(in: room, type: "wallsocket")

                    if !lights.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("조명")
                            if lights.count == 1, let light = lights.first {
                                LightWideTile(device: light, busy: home.busy.contains(light.uid)) {
                                    home.setLight(light, on: light.isOn != true)
                                }
                            } else {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                                    ForEach(lights) { light in
                                        LightTile(device: light, busy: home.busy.contains(light.uid)) {
                                            home.setLight(light, on: light.isOn != true)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !climate.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("냉난방")
                            ForEach(climate) { device in
                                Button { climateUID = device.uid } label: {
                                    ClimateRow(device: device, busy: home.busy.contains(device.uid))
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                    }

                    if !sockets.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("콘센트")
                            VStack(spacing: 0) {
                                ForEach(Array(sockets.enumerated()), id: \.element.id) { index, socket in
                                    if index > 0 { Divider().padding(.leading, 58) }
                                    ToggleRow(symbol: "powerplug.fill", tint: .green, title: socket.displayName,
                                              isOn: socket.isOn == true, busy: home.busy.contains(socket.uid)) {
                                        home.setSocket(socket, on: $0)
                                    }
                                }
                            }
                            .background(CardBackground())
                        }
                    }

                    if lights.isEmpty && climate.isEmpty && sockets.isEmpty && !home.isLoading {
                        ContentUnavailableView("기기를 불러오지 못했어요", systemImage: "house",
                                               description: Text("아래로 당겨 새로고침하세요."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }

                    WholeHomeSection(confirmAllOff: $confirmAllOff)

                    if let updated = home.lastUpdated {
                        Text("업데이트 \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Room.display(home.selectedRoom))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if home.isLoading {
                        ProgressView()
                    } else {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
            }
            .refreshable { await home.refresh(quiet: true) }
            .sheet(item: Binding(get: { climateUID.map { SheetID(id: $0) } }, set: { climateUID = $0?.id })) { item in
                ClimateSheet(uid: item.id)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog("집 안의 모든 조명을 끌까요?", isPresented: $confirmAllOff, titleVisibility: .visible) {
                Button("모든 조명 끄기", role: .destructive) { home.allLightsOff() }
            }
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-demoClimate"),
                   let aircon = home.devices(in: home.selectedRoom, type: "aircon").first {
                    climateUID = aircon.uid
                }
            }
        }
    }
}

struct SheetID: Identifiable {
    let id: String
}

struct RoomPicker: View {
    let rooms: [String]
    @Binding var selection: String

    var body: some View {
        if rooms.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(rooms, id: \.self) { room in
                        let selected = room == selection
                        Button { selection = room } label: {
                            Text(Room.display(room))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(selected ? Color.primary : Color(.tertiarySystemFill)))
                                .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selection)
        }
    }
}

struct LightTile: View {
    let device: Device
    let busy: Bool
    let action: () -> Void

    private var isOn: Bool { device.isOn == true }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    IconBadge(symbol: isOn ? "lightbulb.fill" : "lightbulb", tint: .yellow, active: isOn, size: 50)
                    Spacer()
                    if busy { ProgressView() }
                }
                Spacer(minLength: 28)
                Text(device.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(device.isOn == nil ? "상태 모름" : (isOn ? "켜짐" : "꺼짐"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .card()
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
        .animation(.easeOut(duration: 0.2), value: isOn)
    }
}

/// 방에 조명이 하나일 때: 가로로 넓은 큰 스위치
struct LightWideTile: View {
    let device: Device
    let busy: Bool
    let action: () -> Void

    private var isOn: Bool { device.isOn == true }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                IconBadge(symbol: isOn ? "lightbulb.fill" : "lightbulb", tint: .yellow, active: isOn, size: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(device.isOn == nil ? "상태 모름" : (isOn ? "켜짐" : "꺼짐"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isOn ? Color.black : Color.secondary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(isOn ? Color.yellow : Color(.tertiarySystemFill)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 18)
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
        .animation(.easeOut(duration: 0.2), value: isOn)
    }
}

struct ClimateRow: View {
    let device: Device
    let busy: Bool

    private var isAircon: Bool { device.type == "aircon" }
    private var tint: Color { isAircon ? .blue : .orange }

    private var summary: String {
        let target = device.setTemp.map { "\($0)°" } ?? "—"
        switch device.isOn {
        case .some(true):
            let mode = isAircon ? AirconMode.title(device.mode) : "난방"
            return "\(mode) · \(target) 설정"
        case .some(false):
            return "꺼짐 · \(target) 설정"
        case .none:
            if device.mode == "out" { return "외출 · \(target) 설정" }
            return "\(target) 설정"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: isAircon ? "snowflake" : "flame.fill", tint: tint, active: device.isOn == true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView()
            } else if let current = device.currentTemp {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(current)°")
                        .font(.system(size: 30, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("현재")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .card()
    }
}

struct ToggleRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let isOn: Bool
    let busy: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, tint: tint, active: isOn, size: 30)
            Text(title)
            Spacer()
            if busy { ProgressView().padding(.trailing, 4) }
            Toggle(title, isOn: Binding(get: { isOn }, set: onChange))
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

struct WholeHomeSection: View {
    @EnvironmentObject private var home: HomeStore
    @Binding var confirmAllOff: Bool

    var body: some View {
        let anyLightOn = home.devices(type: "light").contains { $0.isOn == true }
        let vent = home.devices(type: "vent").first
        let gas = home.devices(type: "gas").first

        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("집 전체")
            VStack(spacing: 0) {
                Button { confirmAllOff = true } label: {
                    HStack(spacing: 14) {
                        IconBadge(symbol: "lightbulb.slash", tint: .yellow, active: anyLightOn, size: 30)
                        Text("모든 조명 끄기").foregroundStyle(.primary)
                        Spacer()
                        Text(anyLightOn ? "\(home.devices(type: "light").filter { $0.isOn == true }.count)개 켜짐" : "모두 꺼짐")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!anyLightOn)

                if let vent {
                    Divider().padding(.leading, 58)
                    ToggleRow(symbol: "fan.fill", tint: .teal, title: "환기", isOn: vent.isOn == true,
                              busy: home.busy.contains(vent.uid)) { home.setPower(vent, on: $0) }
                }

                if let gas {
                    Divider().padding(.leading, 58)
                    HStack(spacing: 14) {
                        IconBadge(symbol: "flame", tint: .red, active: gas.status != "close", size: 30)
                        Text("가스 밸브")
                        Spacer()
                        if gas.status == "close" {
                            Text("잠김").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Button("잠그기") { home.closeGas(gas) }
                                .buttonStyle(.bordered)
                                .tint(.red)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
            }
            .background(CardBackground())
        }
    }
}
