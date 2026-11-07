import Foundation

/// iPhone 에서 직접 https://smartelife.apt.co.kr 와 통신하는 클라이언트.
/// 요청 형식은 검증된 파이썬 클라이언트(pickle-smarthome app/elife.py)를 그대로 옮겼다.
///  - 로그인: POST /common/nativeToken.ajax → POST /login.ajax (AES 암호화 ID/PW)
///  - 기기 목록/상태: GET /controls/home.do (Bearer + dpk 헤더) 의 _deviceListByType
///  - 조명/콘센트 on·off: POST /device/control/all.ajax {type, uid, control, is_control_all:"N"}
///  - 조명 밝기: POST /device/control.ajax {type:"light", uid, operation:{value: 1~100}}
///  - 에어컨/난방/환기/가스: POST /device/control.ajax {type, uid, operation}
///  - 로그아웃: POST /common/disablePush.ajax
///
/// 세션 전략 (원래 쓰던 방식): **조작할 때만** 로그인 → 조작 → 바로 로그아웃.
/// 서버가 한 기기만 로그인시키므로, 로그인을 오래 붙잡고 있지 않아야 공식 앱도 같이 쓸 수 있다.
/// 연달아 누른 조작은 한 번의 로그인으로 묶고, 마지막 조작 2.5초 뒤 로그아웃한다.
actor ElifeClient {
    static let shared = ElifeClient()

    static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 14; SM-S918B Build/UP1A.231005.007) DAELIM/ANDROID"
    private static let logoutDelay: Duration = .milliseconds(2500)
    private let base = "https://smartelife.apt.co.kr"

    private var session: URLSession = ElifeClient.makeSession()
    private var token = ""
    private var pageCSRF = ""
    private var loggedIn = false
    private var inFlight = 0
    private var logoutTask: Task<Void, Never>?
    private let deviceUUID: String

    init() {
        // v1.0.0 에서 남겨둔 세션 정보는 더 이상 쓰지 않으므로 정리
        SecureStore.set(nil, for: "token")
        SecureStore.set(nil, for: "cookies")
        if let saved = SecureStore.string("deviceUUID") {
            deviceUUID = saved
        } else {
            let fresh = UUID().uuidString.lowercased()
            SecureStore.setString(fresh, for: "deviceUUID")
            deviceUUID = fresh
        }
    }

    /// 파이썬 requests.Session() 처럼, 로그인마다 쿠키가 비어 있는 새 세션
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }

    // MARK: - Public API (모두 로그인 → 작업 → 로그아웃 예약)

    /// 계정 확인용 로그인 (로그인 화면에서 1회). 성공하면 바로 로그아웃한다.
    func verify(id: String, password: String) async throws -> [Device] {
        try await login(id: id, password: password)
        defer { scheduleLogout() }
        return try await loadHome()
    }

    /// 기기 목록 + 현재 상태
    func fetchDevices() async throws -> [Device] {
        try await withSession { try await self.loadHome() }
    }

    /// 조명 / 콘센트 on·off
    func controlAll(type: String, uid: String, control: String) async throws {
        try await withSession {
            try await self.postControl("/device/control/all.ajax", [
                "type": type, "uid": uid, "control": control, "is_control_all": "N",
            ])
        }
    }

    /// 에어컨 / 난방 / 환기 / 가스 / 조명 밝기
    /// operation 예) ["control": "on"], ["set_temp": "26"], ["mode": "cool"], ["value": 80]
    func control(type: String, uid: String, operation: [String: Any]) async throws {
        try await withSession {
            try await self.postControl("/device/control.ajax", [
                "type": type, "uid": uid, "operation": operation,
            ])
        }
    }

    /// 대기 중인 로그아웃을 지금 바로 실행 (앱이 백그라운드로 갈 때)
    func logoutNow() async {
        logoutTask?.cancel()
        logoutTask = nil
        guard loggedIn, inFlight == 0 else { return }
        loggedIn = false
        _ = try? await send("/common/disablePush.ajax", json: [:], headers: ["_csrf": pageCSRF])
        token = ""
        pageCSRF = ""
        session.invalidateAndCancel()
        session = Self.makeSession()
    }

    // MARK: - Session

    private func withSession<T>(_ work: () async throws -> T) async throws -> T {
        logoutTask?.cancel()
        logoutTask = nil
        inFlight += 1
        defer {
            inFlight -= 1
            scheduleLogout()
        }
        if !loggedIn {
            try await loginWithSavedAccount()
        }
        do {
            return try await work()
        } catch ElifeError.noLogin {
            // 그 사이 다른 기기(공식 앱)가 로그인해서 끊긴 경우: 1회만 다시 로그인
            loggedIn = false
            try await loginWithSavedAccount()
            return try await work()
        }
    }

    private func scheduleLogout() {
        guard inFlight == 0, loggedIn else { return }
        logoutTask?.cancel()
        logoutTask = Task { [weak self] in
            try? await Task.sleep(for: ElifeClient.logoutDelay)
            if Task.isCancelled { return }
            await self?.logoutNow()
        }
    }

    private func loginWithSavedAccount() async throws {
        guard let credentials = CredentialStore.load() else { throw ElifeError.needsCredentials }
        try await login(id: credentials.id, password: credentials.password)
        _ = try await loadHome()   // 제어용 페이지 _csrf 확보
    }

    private func login(id: String, password: String) async throws {
        session.invalidateAndCancel()
        session = Self.makeSession()
        loggedIn = false
        pageCSRF = ""
        let (tokenData, tokenCode) = try await send("/common/nativeToken.ajax", json: [:])
        guard tokenCode == 200 else { throw ElifeError.http(tokenCode) }
        guard let csrf = try object(tokenData)["value"] as? String, !csrf.isEmpty else {
            throw ElifeError.parse("로그인 토큰을 받지 못했어요")
        }
        let body: [String: Any] = [
            "input_acc_os_info": "android",
            "input_dv_make_info": "samsung",
            "input_dv_model_info": "SM-S918B",
            "input_dv_osver_info": "14",
            "input_push_token": "",
            "input_dv_uuid": deviceUUID,
            "input_flag": "login",
            "input_hm_cd": "",
            "input_memb_uid": "",
            "input_version": "1.2.18",
            "input_username": ElifeCrypto.encrypt(id),
            "input_password": ElifeCrypto.encrypt(password),
            "input_auto_login": "off",
        ]
        let (data, code) = try await send("/login.ajax", json: body, headers: ["_csrf": csrf])
        guard code == 200 else { throw ElifeError.http(code) }
        let json = try object(data)
        guard Self.isTrue(json["result"]) else {
            let message = (json["errCodeMsg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? json["errCode"].map { "\($0)" }
                ?? json["reason"].map { "\($0)" }
                ?? "알 수 없는 오류"
            throw ElifeError.loginFailed(message)
        }
        token = (json["daelim_elife"] as? String) ?? ""
        pageCSRF = csrf
        loggedIn = true
    }

    private func loadHome() async throws -> [Device] {
        let (data, code) = try await send("/controls/home.do", method: "GET", headers: webviewHeaders())
        guard code == 200 else { throw ElifeError.http(code) }
        let html = String(decoding: data, as: UTF8.self)
        if html.contains("장시간 미사용") || String(html.prefix(4000)).contains("jsBridge_callLoginView") {
            throw ElifeError.noLogin
        }
        if let csrf = Self.firstMatch(#"'_csrf':\s*'([^']+)'"#, in: html) {
            pageCSRF = csrf
        }
        guard let listJSON = Self.firstMatch(#"_deviceListByType = '(\[.*?\])';"#, in: html, dotAll: true) else {
            throw ElifeError.parse("기기 목록을 읽지 못했어요")
        }
        return try Device.parse(listJSON)
    }

    private func webviewHeaders() -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = formatter.string(from: Date())
        let dpkSeed = ElifeCrypto.sha256Hex(UUID().uuidString.lowercased() + "daelim")
        return [
            "Authorization": "Bearer " + ElifeCrypto.encrypt(token + "::" + timestamp),
            "dpk": ElifeCrypto.encrypt(dpkSeed),
        ]
    }

    private func postControl(_ path: String, _ body: [String: Any]) async throws {
        let (data, code) = try await send(path, json: body, headers: ["_csrf": pageCSRF, "daelim_elife": token])
        guard code == 200 else { throw ElifeError.http(code) }
        let json = try object(data)
        if Self.isFalse(json["result"]) {
            let errCode = json["errCode"].map { "\($0)" } ?? ""
            if errCode == "NO_LOGIN" { throw ElifeError.noLogin }
            if errCode == "NOT_AUTH" { throw ElifeError.notAuthorized }
            let message = (json["errCodeMsg"] as? String) ?? ""
            throw ElifeError.server([errCode, message].filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    // MARK: - HTTP

    private func send(_ path: String, method: String = "POST", json: [String: Any]? = nil,
                      headers: [String: String] = [:]) async throws -> (Data, Int) {
        guard let url = URL(string: base + path) else { throw ElifeError.parse("잘못된 주소") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw ElifeError.network(error.localizedDescription)
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ElifeError.parse("서버 응답을 읽지 못했어요")
        }
        return json
    }

    private static func isTrue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return text == "true" }
        return false
    }

    private static func isFalse(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return !flag }
        if let text = value as? String { return text == "false" }
        return false
    }

    private static func firstMatch(_ pattern: String, in text: String, dotAll: Bool = false) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : []) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}
