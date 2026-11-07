import SwiftUI

/// 카드 배경 (설정 앱의 그룹 셀과 같은 톤)
struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding).background(CardBackground())
    }
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// 눌렀을 때 살짝 작아지는 버튼
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// 둥근 아이콘 배지
struct IconBadge: View {
    let symbol: String
    let tint: Color
    let active: Bool
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(active ? tint : Color.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(active ? tint.opacity(0.16) : Color(.tertiarySystemFill)))
    }
}

struct StatusBanner: View {
    let text: String
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .card(padding: 14)
    }
}

/// - / + 원형 버튼
struct RoundButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color(.tertiarySystemFill)))
                .foregroundStyle(.primary)
        }
        .buttonStyle(PressableStyle())
    }
}
