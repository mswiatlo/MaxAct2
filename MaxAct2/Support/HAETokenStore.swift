import Foundation
import Security
import os

/// Where Health Auto Export's bearer token is kept (issue 48). Synchronous, unlike the Strava
/// store: the token field binds straight to it.
protocol HAETokenStore: AnyObject {
    func token() -> String?
    func save(token: String?) throws
}

/// In memory only, for UI tests and the unit-test host: never the Keychain (see
/// `InMemorySecretStore` for why).
final class InMemoryHAETokenStore: HAETokenStore {
    private var stored: String?

    init(token: String? = nil) { stored = token }

    func token() -> String? { stored }
    func save(token: String?) throws { stored = token }
}

/// The token in the login Keychain, beside the Strava items but under its own service.
///
/// It used to live in the app's preferences, on the grounds that HAE can regenerate it at will.
/// But it grants the whole Health export to anyone on the same network while the server runs, and
/// preferences are a plain file that backups and other tools read freely.
final class KeychainHAETokenStore: HAETokenStore {
    private static let log = Logger(subsystem: "com.swiatlowski.MaxAct", category: "keychain")

    private let query: [String: Any]

    init(service: String = "com.swiatlowski.MaxAct.hae") {
        query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "token",
        ]
    }

    func token() -> String? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Self.log.error("Reading the HAE token: \(KeychainError(status: status).description, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(token: String?) throws {
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrLabel as String] = "MaxAct — Health Auto Export token"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
