import Foundation
import Security

protocol APIKeyStoreProtocol: Sendable {
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

enum APIKeyStoreError: Error, LocalizedError, Sendable {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串错误：\(message)"
        }
    }
}

final class KeychainAPIKeyStore: APIKeyStoreProtocol {
    private let service: String
    private let account: String

    init(
        service: String = Bundle.main.bundleIdentifier ?? "com.deepseek.stats",
        account: String = "deepseek-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APIKeyStoreError.keychain(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(updateStatus)
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw APIKeyStoreError.keychain(addStatus) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum APIKeySource: Sendable, Equatable {
    case keychain
    case environment
    case legacyFile
    case missing
}

actor APIKeyProvider {
    private let keyStore: any APIKeyStoreProtocol
    private let environment: @Sendable () -> [String: String]
    private let legacyFileURL: URL

    init(
        keyStore: any APIKeyStoreProtocol,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        legacyFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/.env")
    ) {
        self.keyStore = keyStore
        self.environment = environment
        self.legacyFileURL = legacyFileURL
    }

    func apiKey() throws -> String {
        if let key = try nonempty(keyStore.read()) { return key }
        if let key = nonempty(environment()["DEEPSEEK_API_KEY"]) { return key }
        if let key = legacyAPIKey() {
            try keyStore.save(key)
            return key
        }
        throw APIError.missingAPIKey
    }

    func source() -> APIKeySource {
        if let stored = try? keyStore.read(), nonempty(stored) != nil { return .keychain }
        if nonempty(environment()["DEEPSEEK_API_KEY"]) != nil { return .environment }
        if legacyAPIKey() != nil { return .legacyFile }
        return .missing
    }

    private func legacyAPIKey() -> String? {
        guard let content = try? String(contentsOf: legacyFileURL, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("export ") {
                trimmed = String(trimmed.dropFirst("export ".count))
            }
            guard trimmed.hasPrefix("DEEPSEEK_API_KEY=") else { continue }
            let value = String(trimmed.dropFirst("DEEPSEEK_API_KEY=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return nonempty(value)
        }
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
