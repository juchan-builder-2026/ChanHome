import SwiftUI

struct RootView: View {
    @EnvironmentObject private var home: HomeStore

    var body: some View {
        if home.isSignedIn {
            MainTabs()
        } else {
            LoginView()
        }
    }
}

struct MainTabs: View {
    @State private var tab: Int = ProcessInfo.processInfo.arguments.contains("-demoSchedules") ? 1 : 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("홈", systemImage: "house.fill") }
                .tag(0)
            ScheduleListView()
                .tabItem { Label("일정", systemImage: "clock.fill") }
                .tag(1)
        }
    }
}

@MainActor
struct LoginView: View {
    @EnvironmentObject private var home: HomeStore
    @State private var id = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case id, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(.orange)
                        Text("집")
                            .font(.largeTitle.weight(.bold))
                        Text("Smart eLife 계정으로 로그인하세요.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("아이디", text: $id)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .id)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("비밀번호", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                } footer: {
                    if let message = home.message {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if home.isLoading {
                                ProgressView()
                            } else {
                                Text("로그인").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(id.isEmpty || password.isEmpty || home.isLoading)
                } footer: {
                    Text("이 iPhone이 아파트 서버(smartelife.apt.co.kr)에 직접 연결합니다. 계정 정보는 이 기기의 키체인에만 저장돼요. Smart eLife는 한 기기만 로그인되므로, 여기서 로그인하면 공식 앱은 로그아웃됩니다.")
                }
            }
        }
    }

    private func submit() {
        guard !id.isEmpty, !password.isEmpty else { return }
        focus = nil
        Task { _ = await home.signIn(id: id.trimmingCharacters(in: .whitespaces), password: password) }
    }
}
