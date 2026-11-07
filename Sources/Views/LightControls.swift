import SwiftUI

/// 제어 센터 스타일의 밝기 막대. 드래그하는 동안은 화면만 바뀌고,
/// 손을 뗄 때 한 번만 서버로 보낸다 (1~100).
struct BrightnessBar: View {
    let value: Int
    let active: Bool
    var height: CGFloat = 46
    let onCommit: (Int) -> Void

    @State private var dragValue: Int?

    private var shown: Int { dragValue ?? value }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat(shown) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(active || dragValue != nil ? Color.yellow : Color(.systemGray3))
                    .frame(width: max(height, width * fraction))
                HStack {
                    Image(systemName: shown < 50 ? "sun.min.fill" : "sun.max.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("\(shown)%")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(shown)))
                }
                .foregroundStyle(active || dragValue != nil ? Color.black.opacity(0.75) : Color.secondary)
                .padding(.horizontal, 16)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let ratio = min(max(gesture.location.x / max(width, 1), 0), 1)
                        dragValue = max(1, Int((ratio * 100).rounded()))
                    }
                    .onEnded { _ in
                        if let final = dragValue { onCommit(final) }
                        dragValue = nil
                    }
            )
            .sensoryFeedback(.selection, trigger: (dragValue ?? 0) / 10)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("밝기")
        .accessibilityValue("\(shown)%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(min(value + 10, 100))
            case .decrement: onCommit(max(value - 10, 1))
            @unknown default: break
            }
        }
    }
}

/// 조명 상세 (여러 조명이 있는 방에서 길게 눌렀을 때)
@MainActor
struct LightSheet: View {
    @EnvironmentObject private var home: HomeStore
    @Environment(\.dismiss) private var dismiss
    let uid: String

    var body: some View {
        NavigationStack {
            Group {
                if let device = home.device(uid) {
                    VStack(spacing: 20) {
                        PowerCard(device: device, tint: .yellow, busy: home.busy.contains(device.uid)) {
                            home.setLight(device, on: $0)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("밝기").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            BrightnessBar(value: home.brightness(of: device), active: device.isOn == true, height: 56) {
                                home.setBrightness(device, $0)
                            }
                        }
                        .card()
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ContentUnavailableView("기기를 찾을 수 없어요", systemImage: "questionmark")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(home.device(uid).map { "\(Room.display($0.room)) \($0.displayName)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
