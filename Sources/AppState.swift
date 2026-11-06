import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var orders: [Order] = []
    @Published var loginPlatform: Platform?
    @Published var busy: Platform?
    @Published var toast: String?
    @Published var lastMessage: String?
    @Published var lastMessageAt: Date?

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

    func cookieSize(_ platform: Platform) -> Int {
        CookieStore.load(for: platform)?.count ?? 0
    }

    /// 顶部横幅提示，6 秒后自动消失；同时留一条「最近一次结果」备查。
    func show(_ message: String) {
        lastMessage = message
        lastMessageAt = Date()
        toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.toast == message { self?.toast = nil }
        }
    }

    /// 从 WebView 里把 cookie 捞出来存进钥匙串。
    func finishLogin(_ platform: Platform) {
        CookieStore.extractFromWebView(for: platform) { header in
            Task { @MainActor in
                if let header, !header.isEmpty {
                    CookieStore.save(header, for: platform)
                    let count = header.split(separator: ";").count
                    self.show("\(platform.name)：已保存 \(count) 个 cookie（\(header.count) 字节）")
                } else {
                    self.show("\(platform.name)：没读到 cookie，可能还没登录成功")
                }
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
                show("\(platform.name)：HTTP \(outcome.httpStatus)，\(outcome.byteCount) 字节，\(outcome.note)")
            } catch {
                busy = nil
                show("\(platform.name)：\(error.localizedDescription)")
            }
        }
    }

    func refreshAll() {
        let platforms = Platform.allCases.filter { isLoggedIn($0) }
        guard !platforms.isEmpty else {
            show("还没有登录任何平台，先去「平台」页登录")
            return
        }
        guard busy == nil else { return }
        Task {
            var lines: [String] = []
            for platform in platforms {
                busy = platform
                do {
                    let outcome = try await OrderClient.fetch(platform: platform)
                    OrderStore.shared.upsert(outcome.orders)
                    lines.append("\(platform.name)：\(outcome.note)")
                } catch {
                    lines.append("\(platform.name)：\(error.localizedDescription)")
                }
            }
            reload()
            busy = nil
            show(lines.joined(separator: "；"))
        }
    }
}
