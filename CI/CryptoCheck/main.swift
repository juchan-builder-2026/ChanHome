import Foundation

// 원본 파이썬 클라이언트(elife.py `_aes_enc`)가 만든 기대값. macOS CI에서 Crypto.swift 와 대조한다.
let vectors: [(String, String)] = [
    ("", "n0ehmFEWOsStlRJp/4dzzw=="),
    ("test-user", "uakO6dkw0e/hNL02xEAB9g=="),
    ("\u{d55c}\u{ae00} \u{c554}\u{d638}\u{d654}", "o7upiyn+jIEul72QFdUqKlt/IKHgK+lyfBaBQ+T9XFw="),
    (String(repeating: "a", count: 32), "kVvsFtqUGlBMowFNDRPh1/FJPaf6G/SpoGTyoTr6sfZhfayDk3uzkd8P/gTbZ4Tb"),
    ("\u{1F506} \u{ce68}\u{c2e4}3", "AT8/ofbMLD4X96D9Ky/c2Q=="),
    ("token-abc::20261107183000", "ld/VxNCkoXKsrlxAmr/GeANGhIC8ksGu8L+KUGW9B1A="),
]

var failed = 0
for (plain, expected) in vectors {
    let got = ElifeCrypto.encrypt(plain)
    if got == expected {
        print("OK   \(plain.debugDescription)")
    } else {
        print("FAIL \(plain.debugDescription): got \(got) expected \(expected)")
        failed += 1
    }
}
precondition(ElifeCrypto.key.count == 32 && ElifeCrypto.iv.count == 16, "key/iv length")
if failed > 0 {
    print("\(failed) vector(s) failed")
    exit(1)
}
print("All \(vectors.count) crypto vectors match the Python reference.")
