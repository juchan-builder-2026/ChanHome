import Foundation
import Security

/// 키체인 저장소. 사이드로드 서명 환경에서 키체인 접근이 막히면
/// 앱 샌드박스 안의 보호 파일로 대신 저장한다.
/// (잠금 상태에서도 예약 실행이 가능하도록 AfterFirstUnlock 등급 사용)
enum SecureStore {
    private static let service = "com.chan.home"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    static func set(_ data: Data?, for key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        try? FileManager.default.removeItem(at: fileURL(key))
        guard let data else { return }
        var query = baseQuery(key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(query as CFDictionary, nil) != errSecSuccess {
            try? data.write(to: fileURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func get(_ key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return data
        }
        return try? Data(contentsOf: fileURL(key))
    }

    static func string(_ key: String) -> String? {
        get(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setString(_ value: String?, for key: String) {
        set(value.map { Data($0.utf8) }, for: key)
    }

    private static func fileURL(_ key: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("secure", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(key)
    }
}

struct Credentials: Codable, Equatable {
    var id: String
    var password: String
}

enum CredentialStore {
    static func load() -> Credentials? {
        SecureStore.get("credentials").flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
    }

    static func save(_ credentials: Credentials) {
        SecureStore.set(try? JSONEncoder().encode(credentials), for: "credentials")
    }

    static func clear() {
        SecureStore.set(nil, for: "credentials")
    }
}

/// 세션 쿠키(만료일 없는 쿠키 포함)를 앱 재시작 후에도 쓰도록 보관.
/// 원본 클라이언트의 session_cookies.json 과 같은 역할.
enum CookieVault {
    private static func isOurs(_ cookie: HTTPCookie) -> Bool {
        cookie.domain.contains("apt.co.kr")
    }

    static func save() {
        let cookies = (HTTPCookieStorage.shared.cookies ?? []).filter(isOurs)
        let list: [[String: String]] = cookies.map {
            ["name": $0.name, "value": $0.value, "domain": $0.domain, "path": $0.path, "secure": $0.isSecure ? "1" : "0"]
        }
        if let data = try? JSONSerialization.data(withJSONObject: list) {
            SecureStore.set(data, for: "cookies")
        }
    }

    static func restore() {
        HTTPCookieStorage.shared.cookieAcceptPolicy = .always
        guard let data = SecureStore.get("cookies"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }
        for item in list {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: item["name"] ?? "",
                .value: item["value"] ?? "",
                .domain: item["domain"] ?? "smartelife.apt.co.kr",
                .path: item["path"] ?? "/",
            ]
            if item["secure"] == "1" { props[.secure] = "TRUE" }
            if let cookie = HTTPCookie(properties: props) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    static func clear() {
        for cookie in (HTTPCookieStorage.shared.cookies ?? []) where isOurs(cookie) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        SecureStore.set(nil, for: "cookies")
    }
}
