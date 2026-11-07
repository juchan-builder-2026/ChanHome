import Foundation

/// iPhone 에서 직접 https://smartelife.apt.co.kr 와 통신하는 클라이언트.
/// 요청 형식은 검증된 파이썬 클라이언트(pickle-smarthome app/elife.py)를 그대로 옮겼다.
///  - 로그인: POST /common/nativeToken.ajax → POST /login.ajax (AES 암호화 ID/PW)
///  - 기기 목록/상태: GET /controls/home.do (Bearer + dpk 헤더) 의 _deviceListByType
///  - 조명/콘센트: POST /device/control/all.ajax {type, uid, control, is_control_all:"N"}
///  - 에어컨/난방/환기/가스: POST /device/control.ajax {type, uid, operation}
/// 서버는 단일 기기 로그인이라, 로그인하면 공식 Smart eLife 앱의 세션은 끊어진다.
actor ElifeClient {
    static let shared = ElifeClient()

    static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 14; SM-S918B Build/UP1A.231005.007) DAELIM/ANDROID"
    private let base = "https://smartelife.apt.co.kr"
    private let session: URLSession
    private var token: String
    private var pageCSRF = ""
    private let deviceUUID: String

    init() {
        CookieVault.restore()
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        token = SecureStore.string("token") ?? ""
        if let saved = SecureStore.string("deviceUUID") {
            deviceUUID = saved
        } else {
            let fresh = UUID().uuidString.lowercased()
            SecureStore.setString(fresh, for: "deviceUUID")
            deviceUUID = fresh
        }
    }

    // MARK: - Public API

    func login(id: String, password: String) async throws {
        CookieVault.clear()
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
        SecureStore.setString(token, for: "token")
    }

    /// 기기 목록 + 현재 상태. 세션이 끊겼고 allowLogin 이면 저장된 계정으로 1회만 재로그인.
    func fetchDevices(allowLogin: Bool) async throws -> [Device] {
        if token.isEmpty {
            guard allowLogin else { throw ElifeError.noLogin }
            try await relogin()
        }
        do {
            return try await loadHome()
        } catch let error as ElifeError where error.isSessionProblem && allowLogin {
            try await relogin()
            return try await loadHome()
        }
    }

    /// 조명 / 콘센트 on·off
    func controlAll(type: String, uid: String, control: String, allowLogin: Bool) async throws {
        try await withSession(allowLogin) {
            try await self.postControl("/device/control/all.ajax", [
                "type": type, "uid": uid, "control": control, "is_control_all": "N",
            ])
        }
    }

    /// 에어컨 / 난방 / 환기 / 가스: operation 예) ["control": "on"], ["set_temp": "26"], ["mode": "cool"]
    func control(type: String, uid: String, operation: [String: String], allowLogin: Bool) async throws {
        try await withSession(allowLogin) {
            try await self.postControl("/device/control.ajax", [
                "type": type, "uid": uid, "operation": operation,
            ])
        }
    }

    func reset() {
        token = ""
        pageCSRF = ""
        SecureStore.setString(nil, for: "token")
        CookieVault.clear()
    }

    // MARK: - Session

    private func relogin() async throws {
        guard let credentials = CredentialStore.load() else { throw ElifeError.needsCredentials }
        try await login(id: credentials.id, password: credentials.password)
    }

    private func withSession(_ allowLogin: Bool, _ operation: () async throws -> Void) async throws {
        if pageCSRF.isEmpty || token.isEmpty {
            _ = try await fetchDevices(allowLogin: allowLogin)
        }
        do {
            try await operation()
        } catch ElifeError.noLogin where allowLogin {
            try await relogin()
            _ = try await loadHome()
            try await operation()
        }
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
            CookieVault.save()
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
