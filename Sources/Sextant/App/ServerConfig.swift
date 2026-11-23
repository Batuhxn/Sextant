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
    }

    private func readToken() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func writeToken(_ t: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(t.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
