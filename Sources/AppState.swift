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
                if !outcome.orders.isEmpty {
                    OrderStore.shared.replace(platform: platform, with: outcome.orders)
                }
                reload()
                busy = nil
                show("\(platform.name)：HTTP \(outcome.httpStatus)，\(outcome.byteCount) 字节，\(outcome.note)")
            } catch {
                busy = nil
                show("\(platform.name)：\(error.localizedDescription)")
            }
        }
    }

    /// 淘宝列表接口只给一句摘要（"运输中预计明天送达"），卡片上想要拼多多那种最新轨迹。
    /// 列表出来之后在后台补抓最近几单的物流页，抓到就把最新一条写回库并刷新界面，不拖慢列表。
    private func enrichTaobaoTrace(limit: Int = 2) {
        guard let cookie = CookieStore.load(for: .tb) else { return }
        let targets = orders
            .filter { $0.platform == .tb && $0.status == .shipped }
            .filter { TraceCache.shared.get("tb:\($0.orderNo)") == nil }
            .prefix(limit)
            .map { $0.orderNo }
        guard !targets.isEmpty else { return }
        Task { [weak self] in
            for no in targets {
                guard let cap = try? await WebOrderFetcher.shared.captureTaobaoLogistics(orderNo: no, cookieHeader: cookie) else { continue }
                let events = TaobaoJdParser.parseTaobaoTraceHTML(cap.html)
                guard let latest = events.first, !latest.desc.isEmpty else { continue }
                // 单号和快递公司也存进缓存，否则缓存命中时详情页上是空的
                let no2 = TaobaoJdParser.trackingNumber(fromLogisticsHTML: cap.html)
                let carrier = orders.first(where: { $0.orderNo == no })?.carrier ?? ""
                TraceCache.shared.put("tb:\(no)", TraceCache.Item(at: Date(), events: events, tracking: no2, carrier: carrier))
                // 卡片上只放描述，时间留给详情页；带时间前缀会被截断反而看不清
                OrderStore.shared.setTrace(orderNo: no, text: latest.desc)
                guard let self else { return }
                if let idx = self.orders.firstIndex(where: { $0.platform == .tb && $0.orderNo == no }) {
                    self.orders[idx].logistics = latest.desc
                }
            }
        }
    }

    func refreshAll() {
        // 京东先断开：抓取路径还没跑通，留着会让每次刷新多花几十秒
        let platforms = Platform.allCases.filter { $0 != .jd && isLoggedIn($0) }
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
                    if !outcome.orders.isEmpty {
                        OrderStore.shared.replace(platform: platform, with: outcome.orders)
                    }
                    lines.append("\(platform.name)：\(outcome.note)")
                } catch {
                    lines.append("\(platform.name)：\(error.localizedDescription)")
                }
            }
            reload()
            busy = nil
            show(lines.joined(separator: "；"))
            enrichTaobaoTrace()
        }
    }
}
