import Foundation
import CommonCrypto
import CryptoKit

/// Smart eLife 앱(v1.2.18)과 동일한 AES-256-CBC / PKCS7 암호화.
/// 키/IV는 APK의 utilStream.json + R.string.key/iv 를 원본 파이썬 클라이언트(elife.py)로
/// 복호화해 얻은 최종 값이다. (CI/CryptoCheck 에서 파이썬 결과와 바이트 단위로 대조)
enum ElifeCrypto {
    static let key: [UInt8] = Array(Data(base64Encoded: "MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=")!)
    static let iv: [UInt8] = Array(Data(base64Encoded: "SHJQdEg0a3ZoS2pWc1BVPQ==")!)

    /// UTF-8 바이트 기준 PKCS7 패딩 후 AES-CBC 암호화 → Base64
    static func encrypt(_ text: String) -> String {
        let input = Array(text.utf8)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key, key.count,
            iv,
            input, input.count,
            &output, output.count,
            &moved
        )
        guard status == kCCSuccess else { return "" }
        return Data(output.prefix(moved)).base64EncodedString()
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
