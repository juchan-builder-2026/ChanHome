import AppIntents
import SwiftUI

/// 단축어 · Siri · 동작 버튼 · 제어 센터 · 자동화 사용법
struct ShortcutsGuideView: View {
    var body: some View {
        List {
            Section {
                SiriTipView(intent: LightPowerIntent())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } footer: {
                Text("앱을 열지 않아도 실행돼요. 실행하는 몇 초 동안만 로그인했다가 바로 로그아웃합니다.")
            }

            Section("Siri에게 말하기") {
                PhraseRow(phrase: "집 불", detail: "방 3 조명 켜기/끄기 전환")
                PhraseRow(phrase: "집 방 3 불 꺼", detail: "방 이름과 켜기·끄기를 함께")
                PhraseRow(phrase: "집 밝기 50%", detail: "17 · 33 · 50 · 67 · 83 · 100% 중 하나")
                PhraseRow(phrase: "집 모든 불 꺼", detail: "집 안 조명 전부 끄기")
                PhraseRow(phrase: "집 에어컨 켜", detail: "온도는 단축어 앱에서 지정")
                PhraseRow(phrase: "집 난방 꺼", detail: "보일러라고 해도 돼요")
                PhraseRow(phrase: "집 상태 알려줘", detail: "조명 · 냉난방 · 콘센트 상태 읽어주기")
                PhraseRow(phrase: "집 가스 잠가", detail: "가스 밸브 잠금")
            }

            Section {
                StepRow(number: 1, text: "설정 → 동작 버튼")
                StepRow(number: 2, text: "옆으로 넘겨 '단축어' 선택")
                StepRow(number: 3, text: "'집' → '조명 켜기/끄기' 선택")
                StepRow(number: 4, text: "버튼을 길게 누르면 방 3 불이 켜졌다 꺼졌다 해요")
            } header: {
                Text("동작 버튼 (iPhone 15 Pro)")
            } footer: {
                Text("밝기를 정해 두고 싶으면 3번에서 '조명 밝기'를 고르면 돼요.")
            }

            Section("제어 센터 · 잠금 화면") {
                StepRow(number: 1, text: "제어 센터를 내리고 왼쪽 위 + → 컨트롤 추가")
                StepRow(number: 2, text: "'단축어 실행' → '집'의 동작 선택")
                StepRow(number: 3, text: "잠금 화면: 길게 눌러 사용자화 → 아래 버튼을 단축어로 바꾸기")
            }

            Section {
                AutomationRow(trigger: "알람이 꺼지면", action: "방 3 밝기 50%")
                AutomationRow(trigger: "수면 집중 모드가 켜지면", action: "모든 조명 끄기")
                AutomationRow(trigger: "집 Wi-Fi에 연결되면", action: "방 3 조명 켜기")
                AutomationRow(trigger: "집을 떠나면", action: "모든 조명 끄기 + 가스 잠그기")
                AutomationRow(trigger: "오후 11시마다", action: "방 3 콘센트 끄기")
            } header: {
                Text("자동화 예시")
            } footer: {
                Text("단축어 앱 → 자동화 → + → 조건 선택 → '즉시 실행'을 켜고 '집'의 동작을 추가하세요. '방 상태 확인' 결과는 알림·메시지 등 다른 동작에 넘길 수 있어요.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("단축어 · Siri")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PhraseRow: View {
    let phrase: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("“\(phrase)”").font(.body.weight(.medium))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.orange))
            Text(text)
        }
    }
}

private struct AutomationRow: View {
    let trigger: String
    let action: String

    var body: some View {
        HStack(spacing: 10) {
            Text(trigger).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.footnote).foregroundStyle(.tertiary)
            Text(action)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }
}
