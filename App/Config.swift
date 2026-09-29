import Foundation
import Security

/// Everything the user sets in Settings. The Bigcapital API key is kept in the Keychain; the rest in UserDefaults.
enum Config {
    private static let d = UserDefaults.standard

    /// Address being tested in Settings before it is saved.
    static var pendingServer: String?

    /// Bigcapital base address, e.g. https://books.example.com (without /api).
    static var server: String {
        var s = (pendingServer ?? d.string(forKey: "server") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/api") { s.removeLast(4) }
        return s
    }
    static var apiKey: String { Keychain.get("apiKey") ?? "" }
    static func setAPIKey(_ key: String) { Keychain.set("apiKey", key.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// Optional: nothing dated before this is written (for a migration: the old system still owns earlier periods).
    static var writeFrom: String? { nonEmpty(d.string(forKey: "writeFrom")) }
    /// Optional: asset account for reimbursable expenses (booked with a manual journal, since Bigcapital can't
    /// categorize a bank transaction to an asset). 0 = off.
    static var reimbursableAccountId: Int? { let v = d.integer(forKey: "reimbursableAccountId"); return v > 0 ? v : nil }
    /// Optional: openpayroll server (https://github.com/.../openpayroll API). Empty = no Payroll tab.
    static var payrollServer: String {
        var s = (d.string(forKey: "payrollServer") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
    /// Optional: before this date pay runs are dry-run previews and can't be approved.
    static var payrollFrom: String? { nonEmpty(d.string(forKey: "payrollFrom")) }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}

enum Keychain {
    private static let service = "bigcapital-ios"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Today's date as YYYY-MM-DD in the phone's time zone.
func todayISO() -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}

func isoDaysAgo(_ n: Int) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date().addingTimeInterval(-Double(n) * 86400))
}
