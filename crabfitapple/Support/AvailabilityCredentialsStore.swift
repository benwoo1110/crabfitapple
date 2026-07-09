import Foundation
import Security

enum AvailabilityCredentialsStore {
    private static let service = Bundle.main.bundleIdentifier ?? "crabfitapple"
    private static let nameAccount = "availability-name"
    private static let passwordAccount = "availability-password"

    static func load() throws -> (name: String, password: String) {
        (
            name: try loadValue(account: nameAccount) ?? "",
            password: try loadValue(account: passwordAccount) ?? ""
        )
    }

    static func save(name: String, password: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try saveValue(trimmedName, account: nameAccount)
        try saveValue(password, account: passwordAccount)
    }

    static func credentialsForRequest() throws -> (name: String, password: String?)? {
        let credentials = try load()
        let trimmedName = credentials.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        return (
            name: trimmedName,
            password: credentials.password.isEmpty ? nil : credentials.password
        )
    }

    private static func loadValue(account: String) throws -> String? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.keychainStatus(status)
        }
    }

    private static func saveValue(_ value: String, account: String) throws {
        guard !value.isEmpty else {
            try deleteValue(account: account)
            return
        }

        let data = Data(value.utf8)
        let query = keychainQuery(account: account)
        let updateAttributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw StoreError.keychainStatus(addStatus)
            }
        default:
            throw StoreError.keychainStatus(updateStatus)
        }
    }

    private static func deleteValue(account: String) throws {
        let status = SecItemDelete(keychainQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychainStatus(status)
        }
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private enum StoreError: LocalizedError {
        case keychainStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychainStatus(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    return "Keychain error: \(message)"
                }

                return "Keychain returned status \(status)."
            }
        }
    }
}
