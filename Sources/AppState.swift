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
    /// 拼多多「快路说没有单、于是后台重抓一次」的并发闸门
    private var pddResync = false
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
        // 京东只认电脑版（thor/pin）：0.36.18 起手机版那条路整条删了，
        // 还留着 pt_key 也算「已登录」会让界面骗人（绿点亮着、刷新却去点电脑版登录）。
        if platform == .jd { return hasPcLogin(platform) }
        return CookieStore.hasLogin(CookieStore.load(for: platform), platform: platform)
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
                var outcome = try await OrderClient.fetch(platform: platform)
                let rawOrders = outcome.orders
                if platform == .pdd {
                    // 库里已被后台重抓确认成 已取消/退款/完成 的单，快路的旧状态不许再显示
                    outcome.orders = OrderClient.droppingTerminalPerStore(outcome.orders, platform: .pdd)
                    // 已经退款/取消、后台重抓确认过「不在列表里」的单，快路再带回来也不要
                    let retired = OrderClient.retiredPddOrders()
                    if !retired.isEmpty {
                        outcome.orders = outcome.orders.filter { !retired.contains($0.orderNo) }
                    }
                    // 快路看不到刚下的单，但不能因此把库里那条抹掉（否则会一会儿有一会儿没有）
                    let kept = OrderClient.keepingStoredActive(outcome.orders, platform: .pdd, excluding: retired)
                    if kept.kept > 0 {
                        outcome.orders = kept.orders
                        outcome.note += "（库里保留 \(kept.kept) 条进行中）"
                    }
                    // 存档太旧（签名可能已过期）时，即使快路说有进行中单，也值得让页面自己再确认一次
                    if outcome.staleMinutes >= 10 { outcome.note += "（快路存档 \(outcome.staleMinutes) 分钟前，后台核一遍）" }
                }
                if !outcome.orders.isEmpty || outcome.authoritative {
                    OrderStore.shared.replace(platform: platform, with: outcome.orders)
                }
                reload()
                busy = nil
                // 京东这条 note 里带「降级」就是被风控挡了：界面上的绿点不该继续说「已登录」
                if platform == .jd {
                    jdBlocked = outcome.note.contains("降级") || outcome.note.contains("被风控")
                    // 取件码/运单号/轨迹都在老版详情页里，刷新完后台补最近几单
                    if !outcome.orders.isEmpty { enrichJdPickup() }
                }
                // 判断要不要后台重抓，看的是「快路这次看到了什么」，不是补过库的结果
                if platform == .pdd {
                    let checking = pddResyncIfNeeded(hasActive: rawOrders.contains { $0.status == .paid || $0.status == .shipped },
                                                     staleMinutes: outcome.staleMinutes)
                    if checking { outcome.note += "（后台核对中，约 5 秒后自动更正）" }
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

    /// 京东的取件码 / 运单号 / 轨迹时间线只在老版详情页里（`details.jd.com/normal/item.action`）。
    /// 刷新完在后台补最近几单，用户点进「物流详情」时就已经有内容，不用再等页面加载。
    private func enrichJdPickup(limit: Int = 3) {
        guard !isDisabled(.jd) else { return }
        guard !jdPickupBusy else { return }
        guard let cookie = CookieStore.loadPc(for: .jd), !cookie.isEmpty else { return }
        let targets = orders
            .filter { $0.platform == .jd && $0.status == .shipped }
            .prefix(limit)
            .map { $0.orderNo }
        guard !targets.isEmpty else { return }
        jdPickupBusy = true
        Task { [weak self] in
            var got: [String] = []
            var traced = 0
            var failed = 0
            for no in targets {
                // 后台用单独的槽，别把用户正在看的详情页顶掉
                guard let detail = await OrderClient.jdPCDetail(
                    orderNo: no, cookieHeader: cookie, slot: "detail-jd-bg", wait: 16) else {
                    failed += 1
                    continue
                }
                // 详情页原样落盘：取件码没读到时，这份文件就是唯一能定位问题的证据
                let head = "【版本】\(OrderClient.appVersion())\n【详情URL】\(detail.url)\n【字数】\(detail.text.count)\n\n"
                try? (head + detail.text).data(using: .utf8)?
                    .write(to: OrderClient.jdDetailFile(for: .jd), options: .atomic)
                if !detail.image.isEmpty {
                    OrderStore.shared.setImage(orderNo: no, url: detail.image)
                }
                let parsed = JdPCDetail.parse(detail.text)
                if !parsed.pickupCode.isEmpty {
                    OrderStore.shared.setPickup(orderNo: no, code: parsed.pickupCode)
                    got.append(parsed.pickupCode)
                }
                let fallback = TaobaoJdParser.parseJdLogistics(text: detail.text, payloadJSON: "")
                let events = parsed.events.isEmpty ? fallback.events : parsed.events
                let tracking = parsed.trackingNo.isEmpty ? fallback.tracking : parsed.trackingNo
                let carrier = parsed.carrier.isEmpty ? fallback.carrier : parsed.carrier
                if !carrier.isEmpty {
                    // 卡片上「待收货」下面那行写的就是它
                    OrderStore.shared.setCarrier(orderNo: no, name: carrier)
                }
                if let latest = events.first, !latest.desc.isEmpty {
                    TraceCache.shared.put("jd:\(no)", TraceCache.Item(
                        at: Date(), events: events, tracking: tracking, carrier: carrier))
                    OrderStore.shared.setTrace(orderNo: no, text: latest.desc)
                    traced += 1
                } else {
                    failed += 1
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.jdPickupBusy = false
                self.reload()
                // 这里是「刷新已经出结果之后」才跑完的后台补抓。用户明确要求过：
                // 点完刷新、结果已经出来了，就不许过几秒再冒一条 —— 所以这一路只静默更新数据，
                // 一个提示都不弹。要排查时看这个 key 或者「订单详情页」那份文件。
                UserDefaults.standard.set("got=\(got.joined(separator: ","))|traced=\(traced)|failed=\(failed)",
                                          forKey: "jd_last_pickup")
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

    /// 拼多多快路只回放旧存档：存档里的 anti_content 是页面当时的签名，
    /// 回放回来「没有待发货/待收货」并不等于现在真的没有（新下的单就是这么被漏掉的）。
    /// 这里在结果出来之后安静地开一次页面重抓，抓到进行中的单就静默换进库 —— 不弹提示。
    /// 返回 true 表示「已经排上后台核对了」（用来在 note 里告诉用户再等几秒）
    @discardableResult
    private func pddResyncIfNeeded(hasActive: Bool, staleMinutes: Int = -1) -> Bool {
        guard !isDisabled(.pdd), !pddResync else { return false }
        // 快路是「当时那张快照」。只要存档超过 1 分钟，无论它说有没有进行中的单，
        // 都让页面自己再问一次：新下的单、刚退掉的单，都是靠这一次纠正过来的。
        let stale = staleMinutes >= 1 || staleMinutes < 0
        // 温页面刚抓过（staleMinutes == 0）就是当下数据，不用再核；
        // 其余情况（重放旧存档 / 未知年龄）都核一次，别去猜 hasActive 准不准。
        guard stale else { return false }
        let lastAt = UserDefaults.standard.double(forKey: "pdd_resync_at")
        // 30 秒地板：连点刷新时不要一次排好几个页面
        guard Date().timeIntervalSince1970 - lastAt > 30 else { return false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pdd_resync_at")
        pddResync = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.pddResync = false } }
            let orders = await OrderClient.pddSilentRescan()
            // 页面这次是带着新签名抓到的，它就是当前事实：哪怕全是已完成的单也要换进去，
            // 否则库里那条「其实已经收货」的进行中旧行会一直挂着（用户 m03369 那类问题）。
            guard !orders.isEmpty else { return }
            await MainActor.run {
                // 这次是页面用新签名问到的当前列表：刚才还在进行中、这次不见了的单 = 已退款/取消，
                // 记下来，免得下一次快路又把它当成待发货带回来。
                let after = Set(orders.map { $0.orderNo })
                let gone = OrderStore.shared.all()
                    .filter { $0.platform == .pdd && ($0.status == .paid || $0.status == .shipped) }
                    .map { $0.orderNo }
                    .filter { !after.contains($0) }
                OrderClient.markPddRetired(gone)
                OrderStore.shared.replace(platform: .pdd, with: orders)
                self?.reload()
            }
        }
        return true
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
            let results = await withTaskGroup(of: (Platform, String, Bool, Int).self) { group -> [(Platform, String, Bool, Int)] in
                for platform in all {
                    group.addTask { @MainActor in
                        do {
                            var outcome = try await OrderClient.fetch(platform: platform)
                            let rawOrders = outcome.orders
                            if platform == .pdd {
                                outcome.orders = OrderClient.droppingTerminalPerStore(outcome.orders, platform: .pdd)
                                let retired = OrderClient.retiredPddOrders()
                                if !retired.isEmpty {
                                    outcome.orders = outcome.orders.filter { !retired.contains($0.orderNo) }
                                }
                                let kept = OrderClient.keepingStoredActive(outcome.orders, platform: .pdd, excluding: retired)
                                if kept.kept > 0 {
                                    outcome.orders = kept.orders
                                    outcome.note += "（库里保留 \(kept.kept) 条进行中）"
                                }
                            }
                            if !outcome.orders.isEmpty {
                                OrderStore.shared.replace(platform: platform, with: outcome.orders)
                            }
                            let pddActive = rawOrders.contains { $0.status == .paid || $0.status == .shipped }
                            return (platform, "\(platform.name)：\(outcome.note)", pddActive, outcome.staleMinutes)
                        } catch {
                            return (platform, "\(platform.name)：\(error.localizedDescription)", false, -1)
                        }
                    }
                }
                var out: [(Platform, String, Bool, Int)] = []
                for await item in group { out.append(item) }
                return out
            }
            if all.contains(.pdd) {
                pddResyncIfNeeded(hasActive: results.first(where: { $0.0 == .pdd })?.2 ?? false,
                                  staleMinutes: results.first(where: { $0.0 == .pdd })?.3 ?? -1)
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