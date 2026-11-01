import Foundation
import Security

/// 토큰은 Keychain에만 둔다 (UserDefaults나 파일에는 쓰지 않는다).
enum Keychain {
    /// 테스트 실행(APP_STORE)은 실제 로그인과 다른 항목을 쓴다.
    private static var service: String {
        let base = (Bundle.main.bundleIdentifier ?? "com.example.exchangemail") + ".tokens"
        return Store.isOverridden ? base + ".test" : base
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        let q = query(account)
        let update = [kSecValueData as String: data] as CFDictionary
        if SecItemUpdate(q as CFDictionary, update) == errSecSuccess { return true }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
