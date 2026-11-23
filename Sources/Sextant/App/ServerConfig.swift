import Foundation
import Security

/// Where the computer (Kılavuz) is and the pairing key. The key lives in the Keychain.
final class ServerConfig {
    static let shared = ServerConfig()
    private let urlKey = "sextant.server"
    private let service = "com.batuhxn.sextant.pairing"

    var server: String? { UserDefaults.standard.string(forKey: urlKey) }
    var token: String? { readToken() }
    var isPaired: Bool { server != nil && token != nil }

    func save(server: String, token: String) {
        UserDefaults.standard.set(server, forKey: urlKey)
        writeToken(token)
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: urlKey)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackFile)
    }

    /// Fallback when the Keychain is unavailable (unsigned simulator builds in CI): a file the app alone
    /// can read, encrypted by iOS until first unlock.
    private var fallbackFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pairing.key")
    }

    private func readToken() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return String(data: d, encoding: .utf8) }
        return (try? Data(contentsOf: fallbackFile)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func writeToken(_ t: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(t.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
            try? FileManager.default.removeItem(at: fallbackFile)
            return
        }
        try? FileManager.default.createDirectory(at: fallbackFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(t.utf8).write(to: fallbackFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
