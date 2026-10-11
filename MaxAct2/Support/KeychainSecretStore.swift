import Foundation
import MaxActCore
import Security

/// What the app needs from a secret store: the client's needs, plus saving the user's API
/// application credentials from Settings.
protocol AppSecretStore: StravaSecretStore {
    func save(credentials: StravaCredentials?) async throws
}

/// Secrets held in memory only, for UI tests.
///
/// **UI tests must not touch the Keychain at all**, not merely a separate service. The app is
/// ad-hoc signed, so every build has a new code signature and the Keychain treats it as a new
/// app: any access can raise a password prompt, which steals focus and left a test unable to bring
/// the app forward ("Running Background"). Measured: a single UI test made five Keychain lookups.
/// In memory, there's nothing to prompt for — and nothing a test could do to the real login.
actor InMemorySecretStore: AppSecretStore {
    private var storedCredentials: StravaCredentials?
    private var storedTokens: StravaTokens?

    func credentials() async -> StravaCredentials? { storedCredentials }
    func tokens() async -> StravaTokens? { storedTokens }
    func save(tokens: StravaTokens?) async throws { storedTokens = tokens }
    func save(credentials: StravaCredentials?) async throws { storedCredentials = credentials }
}

/// Strava credentials and tokens in the login Keychain.
///
/// Two generic-password items under one service: the user's API application (client ID and
/// secret) and the OAuth tokens. Both are JSON, so adding a field later doesn't mean a migration.
/// `WhenUnlocked`, because nothing here needs to work while the Mac is locked.
///
/// UI tests don't use this at all — see `InMemorySecretStore`.
actor KeychainSecretStore: AppSecretStore {
    private let service: String

    private enum Account: String {
        case credentials
        case tokens
    }

    init(service: String = "com.swiatlowski.MaxAct.strava") {
        self.service = service
    }

    func credentials() async -> StravaCredentials? { read(.credentials) }
    func tokens() async -> StravaTokens? { read(.tokens) }

    func save(tokens: StravaTokens?) async throws { try write(tokens, as: .tokens) }
    func save(credentials: StravaCredentials?) throws { try write(credentials, as: .credentials) }

    // MARK: - Keychain

    private func read<T: Decodable>(_ account: Account) -> T? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T?, as account: Account) throws {
        let query = baseQuery(account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }
        let data = try JSONEncoder().encode(value)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrLabel as String] = "MaxAct — Strava \(account.rawValue)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}
