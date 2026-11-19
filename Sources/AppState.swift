import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var orders: [Order] = []
    @Published var loginPlatform: Platform?
    @Published var busy: Platform?
    @Published var toast: String?
    @Published var lastMessage: String?
    @Published var lastMessageAt: Date?
    /// 平台页用来排障：轨迹库有几行、最近写了什么
    @Published var traceInfo: String = ""
    /// 不参与“刷新全部”的平台（存在 UserDefaults，重启后保留）
    @Published var disabledPlatforms: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "disabled_platforms") ?? [])
    /// 最近一次后台补抓做了什么
    @Published var enrichInfo: String = ""
    /// 电脑版登录（京东 thor/pin），和 loginPlatform 分开走
    @Published var pcLoginPlatform: Platform?
    /// 京东上次刷新是否被风控挡了 —— 有它就说明那个绿点不可信
    @Published var jdBlocked: Bool = false
    /// 后台补京东取件码的时候不要并发开第二个 WebView
    private var jdPickupBusy = false
    /// 「体检」按钮是否正在跑（防止连点开出两个 WebView）
    @Published var probing = false

    init() {
        reload()
    }

    func reload() {
        orders = OrderStore.shared.all()
        traceInfo = OrderStore.shared.traceDebug()
    }

    func isDisabled(_ platform: Platform) -> Bool { disabledPlatforms.contains(platform.rawValue) }

    func setDisabled(_ platform: Platform, _ value: Bool) {
        if value { disabledPlatforms.insert(platform.rawValue) } else { disabledPlatforms.remove(platform.rawValue) }
        UserDefaults.standard.set(Array(disabledPlatforms), forKey: "disabled_platforms")
    }

    func isLoggedIn(_ platform: Platform) -> Bool {
        if CookieStore.hasLogin(CookieStore.load(for: platform), platform: platform) { return true }
        // 京东有电脑版会话（thor/pin）也算登录：手机版失效时它是唯一的活口，
        // 以前这里只认 pt_key，电脑版登得好好的，界面还是一句「先去登录」。
        if platform == .jd, hasPcLogin(platform) { return true }
        return false
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

    /// 刚登录完不要立刻自动刷新（京东那页太大，容易把内存顶爆）
    private var suppressAutoRefreshUntil = Date.distantPast

    /// 从 WebView 里把 cookie 捞出来存进钥匙串。
    func finishLogin(_ platform: Platform) {
        CookieStore.extractFromWebView(for: platform) { header in
            Task { @MainActor in
                if let header, !header.isEmpty {
                    CookieStore.save(header, for: platform)
                    let count = header.split(separator: ";").count
                    var extra = ""
                    if platform == .jd {
                        let keyLen = header.components(separatedBy: ";")
                            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pt_key=") })?.count ?? 0
                        extra = keyLen > 0 ? "，pt_key \(max(keyLen - 7, 0)) 位" : "，没看到 pt_key"
                    }
                    self.show("\(platform.name)：已保存 \(count) 个 cookie（\(header.count) 字节\(extra)）")
                } else {
                    self.show("\(platform.name)：没读到 cookie，可能还没登录成功")
                }
                self.suppressAutoRefreshUntil = Date().addingTimeInterval(120)
                self.reload()
            }
        }
    }

    func logout(_ platform: Platform) {
        CookieStore.delete(for: platform)
        objectWillChange.send()
    }

    // MARK: - 电脑版会话（京东专用）

    func hasPcLogin(_ platform: Platform) -> Bool {
        guard let pc = CookieStore.loadPc(for: platform) else { return false }
        return platform.pcEssentialCookies.allSatisfy { pc.contains("\($0)=") }
    }

    func pcLoginTime(_ platform: Platform) -> Date? { CookieStore.savedAtPc(for: platform) }

    func pcCookieSize(_ platform: Platform) -> Int { CookieStore.loadPc(for: platform)?.count ?? 0 }

    /// 电脑版登录完成：只存 thor/pin 那套，不覆盖手机版凭证。
    func finishPcLogin(_ platform: Platform) {
        CookieStore.extractFromWebView(for: platform) { header in
            Task { @MainActor in
                guard let header, !header.isEmpty else {
                    self.show("\(platform.name)：电脑版登录没有读到 cookie")
                    return
                }
                CookieStore.savePc(header, for: platform)
                let hasThor = header.contains("thor=")
                let hasPin = header.contains("pin=")
                var extra = "thor " + (hasThor ? "有" : "无") + "·pin " + (hasPin ? "有" : "无")
                if !hasThor {
                    extra += "（没登成或者登的是手机版，下次刷新会走手机版那条路）"
                }
                self.show("\(platform.name)：电脑版凭证已存 \(header.count) 字节（\(extra)）")
                self.reload()
            }
        }
    }

    func clearPcLogin(_ platform: Platform) {
        CookieStore.deletePc(for: platform)
        show("\(platform.name)：已清掉电脑版凭证")
        reload()
    }

    /// 清空某平台的登录态：钥匙串 + WebView 里的 cookie + 京东重放存档。
    /// 京东会话被服务端作废后，只重登不清 WebView 是没用的（旧 cookie 会一直盖着新的）。
    func clearLogin(_ platform: Platform) {
        CookieStore.delete(for: platform)
        if platform == .jd { JdFast.clear() }
        CookieStore.clearWebViewCookies(for: platform) { count in
            Task { @MainActor in
                self.show("\(platform.name)：已清掉 \(count) 个网页 cookie，请重新登录")
                self.reload()
            }
        }
    }

    func refresh(_ platform: Platform) {
        guard busy == nil else { return }
        busy = platform
        Task {
            do {
                let outcome = try await OrderClient.fetch(platform: platform)
                if !outcome.orders.isEmpty || outcome.authoritative {
                    OrderStore.shared.replace(platform: platform, with: outcome.orders)
                }
                reload()
                busy = nil
                // 京东这条 note 里带「降级」就是被风控挡了：界面上的绿点不该继续说「已登录」
                if platform == .jd {
                    jdBlocked = outcome.note.contains("降级") || outcome.note.contains("被风控")
                    if !outcome.orders.isEmpty { enrichJdPickup() }
                }
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
        // 用户把淘宝的刷新关掉了，这个后台补抓也不该偷偷跑（会真的去打淘宝接口）
        guard !isDisabled(.tb) else { return }
        guard let cookie = CookieStore.load(for: .tb) else { return }
        let targets = orders
            .filter { $0.platform == .tb && $0.status == .shipped }
            .filter { TraceCache.shared.get("tb:\($0.orderNo)") == nil }
            .prefix(limit)
            .map { $0.orderNo }
        guard !targets.isEmpty else {
            enrichInfo = "补抓：没有需要补的（缓存里都有）"
            return
        }
        Task { [weak self] in
            for no in targets {
                guard let cap = try? await WebOrderFetcher.shared.captureTaobaoLogistics(orderNo: no, cookieHeader: cookie) else { continue }
                let events = TaobaoJdParser.parseTaobaoTraceHTML(cap.html)
                guard let latest = events.first, !latest.desc.isEmpty else { continue }
                // 单号和快递公司也存进缓存，否则缓存命中时详情页上是空的
                var no2 = TaobaoJdParser.trackingNumber(fromText: cap.text)
                if no2.isEmpty { no2 = TaobaoJdParser.trackingNumber(fromLogisticsHTML: cap.html) }
                let carrier = orders.first(where: { $0.orderNo == no })?.carrier ?? ""
                TraceCache.shared.put("tb:\(no)", TraceCache.Item(at: Date(), events: events, tracking: no2, carrier: carrier))
                // 卡片上只放描述，时间留给详情页；带时间前缀会被截断反而看不清
                OrderStore.shared.setTrace(orderNo: no, text: latest.desc)
                guard let self else { return }
                if let idx = self.orders.firstIndex(where: { $0.platform == .tb && $0.orderNo == no }) {
                    self.orders[idx].logistics = latest.desc
                }
                self.traceInfo = OrderStore.shared.traceDebug()
                self.enrichInfo = "补抓：\(no) → \(latest.desc.prefix(20))"
            }
        }
    }

    /// 「体检」：开一次京东「我的」页，直接回答「这份登录态现在还认不认」。
    /// 京东失效时刷新只会返回空列表，用户看不出是网络问题还是登录问题。
    func probeJdSession() {
        guard !probing else { return }
        guard let cookie = CookieStore.load(for: .jd), !cookie.isEmpty else {
            show("京东还没登录")
            return
        }
        probing = true
        Task {
            let result = await WebOrderFetcher.shared.jdSessionProbe(cookieHeader: cookie)
            probing = false
            jdBlocked = result.contains("已失效") || result.contains("没结论")
            show(result)
        }
    }

    /// 京东的取件码和物流摘要只能从订单详情页里读（列表接口里压根没有这两个字段）。    /// 刷新完在后台补最近一两单，用户点进「物流详情」时就已经有内容，不用再等页面加载。
    private func enrichJdPickup(limit: Int = 2) {
        guard !isDisabled(.jd) else { return }
        guard !jdPickupBusy else { return }
        guard let cookie = CookieStore.load(for: .jd), !cookie.isEmpty else { return }
        let targets = orders
            .filter { $0.platform == .jd && $0.status == .shipped && $0.pickupCode.isEmpty }
            .prefix(limit)
            .map { $0.orderNo }
        guard !targets.isEmpty else { return }
        jdPickupBusy = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.jdPickupBusy = false } }
            var got: [String] = []
            var blocked = 0
            for no in targets {
                // 后台用单独的槽，别把用户正在看的详情页顶掉
                guard let cap = try? await OrderClient.captureJdDetail(
                    orderNo: no, cookieHeader: cookie, slot: "detail-jd-bg", seconds: 7) else { continue }
                if cap.text.contains("账号信息获取失败") || cap.text.contains("免费注册") { blocked += 1 }
                let code = DetailParser.pickupCode(from: cap.text)
                if !code.isEmpty {
                    OrderStore.shared.setPickup(orderNo: no, code: code)
                    got.append(code)
                }
                let parsed = TaobaoJdParser.parseJdLogistics(text: cap.text, payloadJSON: cap.payloadJSON)
                if let latest = parsed.events.first, !latest.desc.isEmpty {
                    TraceCache.shared.put("jd:\(no)", TraceCache.Item(
                        at: Date(), events: parsed.events, tracking: parsed.tracking, carrier: parsed.carrier))
                    OrderStore.shared.setTrace(orderNo: no, text: latest.desc)
                }
                guard let self else { return }
                await MainActor.run { self.reload() }
            }
            // 取件码是异步补的，用户不会盯着看 —— 结果必须说出来，否则「没出现」永远没法归因
            guard let self else { return }
            if !got.isEmpty {
                self.show("京东取件码：\(got.joined(separator: "、"))")
            } else if blocked > 0 {
                self.show("京东取件码没读到：详情页显示「请登录 / 账号信息获取失败」，先去「平台」页重登京东")
            } else {
                self.show("京东取件码没读到：详情页里没有「取件码」字样")
            }
        }
    }

    /// 打开 App / 回到前台时，如果数据已经旧了就在后台刷一次：
    /// 用户看到的是「已经好的列表」，而不是等 7 秒的转圈。
    func autoRefreshIfStale(minutes: Int = 3) {
        if Date() < suppressAutoRefreshUntil { return }
        guard busy == nil else { return }
        let last = UserDefaults.standard.double(forKey: "last_refresh_at")
        let age = Date().timeIntervalSince1970 - last
        guard last == 0 || age > Double(minutes * 60) else { return }
        refreshAll(quiet: true)
    }

    func refreshAll(quiet: Bool = false) {
        let all = Platform.allCases.filter { isLoggedIn($0) && !disabledPlatforms.contains($0.rawValue) }
        guard !all.isEmpty else {
            show("还没有登录任何平台，先去「平台」页登录")
            return
        }
        guard busy == nil else { return }
        Task {
            busy = all.first
            // 各平台各自开一个 WebView 并行抓，总耗时取最大值而不是相加
            let results = await withTaskGroup(of: (Platform, String).self) { group -> [(Platform, String)] in
                for platform in all {
                    group.addTask { @MainActor in
                        do {
                            let outcome = try await OrderClient.fetch(platform: platform)
                            if !outcome.orders.isEmpty {
                                OrderStore.shared.replace(platform: platform, with: outcome.orders)
                            }
                            return (platform, "\(platform.name)：\(outcome.note)")
                        } catch {
                            return (platform, "\(platform.name)：\(error.localizedDescription)")
                        }
                    }
                }
                var out: [(Platform, String)] = []
                for await item in group { out.append(item) }
                return out
            }
            var lines = all.map { p in results.first(where: { $0.0 == p })?.1 ?? "" }
            lines.removeAll { $0.isEmpty }
            reload()
            busy = nil
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_refresh_at")
            if !quiet { show(lines.joined(separator: "；")) }
            enrichTaobaoTrace()
            enrichJdPickup()
            BackgroundRefresh.schedule()
            let changes = BackgroundRefresh.diff(orders: orders)
            if !quiet { BackgroundRefresh.post(changes) }
        }
    }
}
