import Foundation
import Security
import WebKit

/// 把 WebView 里登录后的 cookie 存进钥匙串，后续抓单直接读出来拼 Cookie 头。
enum CookieStore {
    private static let service = "com.abdd.orderpocket.cookies"

    static func save(_ value: String, for platform: Platform) {
        let data = Data(value.utf8)
        let account = platform.rawValue

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[cookie] keychain save failed: \(status)")
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "cookie_saved_at_\(account)")
    }

    static func load(for platform: Platform) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: platform.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for platform: Platform) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: platform.rawValue
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "cookie_saved_at_\(platform.rawValue)")
    }

    static func savedAt(for platform: Platform) -> Date? {
        let ts = UserDefaults.standard.double(forKey: "cookie_saved_at_\(platform.rawValue)")
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// 从 WebView 的 cookie 仓库里捞出该平台的所有 cookie，拼成 `a=1; b=2`。
    static func extractFromWebView(for platform: Platform, completion: @escaping (String?) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let hints = platform.cookieDomainHints
            let matched = cookies.filter { cookie in
                hints.contains { cookie.domain.contains($0) }
            }
            guard !matched.isEmpty else {
                completion(nil)
                return
            }
            // 同名 cookie 可能挂在多个域名上，按域名从粗到细排，细的覆盖粗的
            var map: [String: String] = [:]
            for cookie in matched.sorted(by: { $0.domain.count < $1.domain.count }) {
                map[cookie.name] = cookie.value
            }
            let header = map
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "; ")
            completion(header)
        }
    }

    /// 判断这份 cookie 头里有没有登录态。
    static func hasLogin(_ header: String?, platform: Platform) -> Bool {
        guard let header, !header.isEmpty else { return false }
        return platform.essentialCookies.contains { header.contains("\($0)=") }
    }

    /// 同步版的提取（async 包装），抓完单后拿来回写，做 token 续期。
    static func currentHeader(for platform: Platform) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            extractFromWebView(for: platform) { header in
                cont.resume(returning: header)
            }
        }
    }
}
