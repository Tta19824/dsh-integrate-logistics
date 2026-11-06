import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var orders: [Order] = []
    @Published var loginPlatform: Platform?
    @Published var busy: Platform?
    @Published var toast: String?
    @Published var showToast = false

    init() {
        reload()
    }

    func reload() {
        orders = OrderStore.shared.all()
    }

    func isLoggedIn(_ platform: Platform) -> Bool {
        CookieStore.hasLogin(CookieStore.load(for: platform), platform: platform)
    }

    func loginTime(_ platform: Platform) -> Date? {
        CookieStore.savedAt(for: platform)
    }

    /// 从 WebView 里把 cookie 捞出来存进钥匙串。
    func finishLogin(_ platform: Platform) {
        CookieStore.extractFromWebView(for: platform) { header in
            Task { @MainActor in
                if let header, !header.isEmpty {
                    CookieStore.save(header, for: platform)
                    let count = header.split(separator: ";").count
                    self.toast = "\(platform.name)：已保存 \(count) 个 cookie"
                } else {
                    self.toast = "\(platform.name)：没读到 cookie，可能还没登录成功"
                }
                self.showToast = true
                self.reload()
            }
        }
    }

    func logout(_ platform: Platform) {
        CookieStore.delete(for: platform)
        objectWillChange.send()
    }

    func refresh(_ platform: Platform) {
        guard busy == nil else { return }
        busy = platform
        Task {
            do {
                let outcome = try await OrderClient.fetch(platform: platform)
                OrderStore.shared.upsert(outcome.orders)
                reload()
                busy = nil
                toast = "\(platform.name)：\(outcome.note)"
            } catch {
                busy = nil
                toast = "\(platform.name)：\(error.localizedDescription)"
            }
            showToast = true
        }
    }

    func refreshAll() {
        let platforms = Platform.allCases.filter { isLoggedIn($0) }
        guard !platforms.isEmpty else {
            toast = "还没有登录任何平台，先去「平台」页登录"
            showToast = true
            return
        }
        guard busy == nil else { return }
        Task {
            for platform in platforms {
                busy = platform
                do {
                    let outcome = try await OrderClient.fetch(platform: platform)
                    OrderStore.shared.upsert(outcome.orders)
                } catch {
                    NSLog("[refresh] \(platform.name) failed: \(error.localizedDescription)")
                }
            }
            reload()
            busy = nil
        }
    }
}
