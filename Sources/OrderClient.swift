import Foundation

struct FetchOutcome {
    var orders: [Order]
    var httpStatus: Int
    var byteCount: Int
    var rawFileURL: URL?
    var note: String
    var payloadJSON: String = ""
    /// 这次抓取是可信的（直连拿到了真实响应），0 条也该覆盖旧数据
    var authoritative: Bool = false
}

enum FetchError: LocalizedError {
    case noCookie
    case badURL
    case http(Int)
    case emptyBody
    case note(String)

    var errorDescription: String? {
        switch self {
        case .noCookie: return "还没有登录，先点「登录」拿到 cookie"
        case .badURL: return "地址拼错了"
        case .http(let code): return "服务器返回 \(code)"
        case .emptyBody: return "页面是空的"
        case .note(let text): return text
        }
    }
}

/// 上一次抓包的诊断信息，给「平台」页显示，方便截图定位问题
struct CaptureInfo {
    var entryCount = 0
    var textChars = 0
    var payloadChars = 0
    var urls: [String] = []
    var entrySizes: [String] = []
    var largestBody = ""
    var writeError = ""
    var pageTitle = ""
    var snippet = ""
    var uaProbe: [String] = []
    var attempts: [String] = []
}

enum OrderClient {
    static var lastCapture = CaptureInfo()

    static func rawDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func latestRawFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("raw_\(platform.rawValue).html")
    }

    static func pageFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("page_\(platform.rawValue).txt")
    }

    static func payloadFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("payload_\(platform.rawValue).json")
    }

    /// 订单列表卡片上的文字（排查取件码用）
    static func cardsFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("cards_\(platform.rawValue).json")
    }

    static func htmlFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("page_\(platform.rawValue).html")
    }

    /// 订单详情页抓到的接口数据（排查店铺名用）
    /// 淘宝 / 京东订单页上的图片与时间摘要
    static func jdInPageFile() -> URL {
        rawDirectory().appendingPathComponent("jd_inpage.txt")
    }

    static func digestFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("digest_\(platform.rawValue).json")
    }

    static func detailPayloadFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("payload_detail_\(platform.rawValue).json")
    }

    /// 淘宝物流轨迹页抓回来的接口数据（排查轨迹用）
    static func tbLogisticsFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("tb_logistics_\(platform.rawValue).json")
    }

    /// 淘宝物流页这次发出的 mtop 请求（URL + 请求体 + 响应），用来做直连重放实验
    static func tbRequestsFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("tb_requests.json")
    }

    /// 淘宝列表页这次发出的 mtop 请求（URL + 请求体 + 响应），用来做直连重放
    static func tbListRequestsFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("tb_list_requests.json")
    }

    /// 用 URLSession 直接抓回来的订单列表页 HTML
    static func tbListRawFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("tb_list_raw_" + platform.rawValue + ".html")
    }

    /// 用 URLSession 直接抓回来的物流页 HTML（对比 WebView 里的那一份）
    static func tbRawHTMLFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("tb_raw_" + platform.rawValue + ".html")
    }

    /// 页面这次加载过的所有资源地址（找出真正的数据接口）
    static func resourcesFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("resources_\(platform.rawValue).json")
    }

    /// 淘宝物流页的 HTML（轨迹可能直接内嵌在初始 HTML 的 JSON 里）
    static func tbLogisticsHTMLFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("tb_logistics_page_\(platform.rawValue).html")
    }

    /// 订单详情页加载过的资源地址
    static func resourcesDetailFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("resources_detail_\(platform.rawValue).json")
    }

    /// 淘宝订单详情页的页面文字（排查快递公司与轨迹用）
    static func captureJdDetail(orderNo: String, cookieHeader: String,
                                slot: String = "detail-jd", seconds: Double = 9) async throws -> WebOrderFetcher.Capture {
        // 京东现在只走电脑版（thor/pin），详情页也得用电脑版的地址。
        // 列表页里捡到的「订单详情」链接最准（带签名），捡不到再退回猜一个。
        let pcMode = cookieHeader.contains("thor=")
        var candidates: [String] = []
        if pcMode {
            // 列表页里捡到的链接最准（带 PassKey）。捡不到就退回不带 PassKey 的同一页 ——
            // 千万别再去 order.jd.com/center/viewOrder.action，那一页只有一句「请上门提货」。
            if let known = JdPCLinks.url(for: orderNo) { candidates.append(known) }
            candidates.append("https://details.jd.com/normal/item.action?orderid=\(orderNo)")
        } else {
            candidates.append("https://trade.m.jd.com/order/n_detail_jdm.shtml?deal_id=\(orderNo)")
            candidates.append("https://order.m.jd.com/orderDetail?orderId=\(orderNo)")
        }
        let urls = candidates.compactMap { URL(string: $0) }
        guard !urls.isEmpty else { throw FetchError.badURL }

        var best: WebOrderFetcher.Capture?
        for (index, url) in urls.enumerated() {
            guard let cap = try? await WebOrderFetcher.shared.capture(
                platform: .jd,
                urls: [url],
                cookieHeader: cookieHeader,
                seconds: seconds,
                clickTabs: false,
                // 电脑版详情页的物流轨迹在「物流信息」里、取件码可能要「展开详细信息」才出来；
                // 找不到这些文字就什么都不点（capture 会自己跳过）。
                clickTexts: pcMode ? ["物流信息", "查看物流", "展开详细信息"] : [],
                scroll: true,
                // 以前只认「运输中/已签收/运单号」这些快递词，自提单页面上写的是
                // 「待取件 / 取件码 15-6-2127 / 投递完成，请上门提货」——一个都不匹配，
                // 于是一定要等满 21 秒的轮询上限，这才是「点进物流详情等很久」的真正原因。
                readyJS: "(/运输中|已签收|派送中|已送达|运单号|承运人|取件码|待取件|提货|自提|投递/.test(document.body.innerText)) ? '1' : '0'",
                slot: slot,
                referer: pcMode ? "https://order.jd.com/center/list.action" : "https://my.m.jd.com/"
            ) else { continue }
            // 京东风控页：「验证一下，购物无忧」，只有几十个字，换下一个地址
            let trimmed = cap.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isJSONError = trimmed.hasPrefix("{") && (trimmed.contains("functionId") || trimmed.contains("\"code\":\"1\""))
            let blocked = (cap.text.count < 300 && (cap.text.contains("快速验证") || cap.text.contains("验证一下"))) || isJSONError
            if blocked { continue }
            if best == nil || cap.text.count > (best?.text.count ?? 0) { best = cap }
            // 已经拿到带物流/取件信息的页面就别再试第二个地址（每个地址都要几秒）
            if cap.text.count > 600, index == 0 { break }
            _ = index
        }
        guard let result = best else { throw FetchError.note("京东详情页被风控拦了（出现验证页），先手动打开一次京东再试") }
        return result
    }

    /// 京东电脑版详情入口：先「在列表里点开订单详情」（`PassKey` 只能这样拿到），
    /// 失败再退回拼 URL 的老办法。返回（最终 URL，正文，商品主图）。
    static func jdPCDetail(orderNo: String, cookieHeader: String,
                           slot: String = "detail-jd", wait: Double = 16) async -> (url: String, text: String, image: String)? {
        let clicked = await WebOrderFetcher.shared.jdPCDetailByClick(
            orderNo: orderNo, cookieHeader: cookieHeader, slot: "\(slot)-click", wait: wait)
        if clicked.hasPrefix("200|") {
            let parts = clicked.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                let url = String(parts[1])
                if url.contains("PassKey") { JdPCLinks.save([orderNo: url]) }
                return (url, String(parts[2]), WebOrderFetcher.shared.lastDetailImage)
            }
        }
        guard let cap = try? await captureJdDetail(orderNo: orderNo, cookieHeader: cookieHeader,
                                                   slot: slot, seconds: 10) else { return nil }
        if cap.finalURL.contains("PassKey") { JdPCLinks.save([orderNo: cap.finalURL]) }
        return (cap.finalURL, cap.text, "")
    }
    static func jdDetailFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("jd_detail_\(platform.rawValue).txt")
    }

    static func tbDetailFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("tb_detail_\(platform.rawValue).txt")
    }

    static func fetch(platform: Platform) async throws -> FetchOutcome {
        // 京东允许「手机版没 cookie、但有电脑版 thor/pin」—— 那条活路由 fetchJd 自己判断，
        // 别在这里一刀切掉（0.36.14 实测：电脑版登上了，刷新还是「先去登录」）。
        if platform == .jd {
            return try await fetchJd()
        }
        guard let cookie = CookieStore.load(for: platform), !cookie.isEmpty else {
            throw FetchError.noCookie
        }
        switch platform {
        case .pdd:
            return try await fetchPinduoduo(cookie: cookie)
        case .tb:
            return try await fetchTaobao(cookie: cookie)
        case .jd:
            return try await fetchJd()
        }
    }

    /// 用真 WebView 打开订单页，让平台自己的 JS 去请求数据，再把渲染结果和接口响应抓回来。
    /// App 启动时预热拼多多订单页（只对已登录的账号做）
    static func warmUp() {
        let cookie = CookieStore.load(for: .pdd) ?? ""
        guard !cookie.isEmpty else { return }
        Task {
            guard let url = URL(string: "https://mobile.pinduoduo.com/order.html") else { return }
            await WebOrderFetcher.shared.warmUp(url: url, cookieHeader: cookie)
        }
    }

    private static func fetchTaobao(cookie: String) async throws -> FetchOutcome {
        let started = Date()
        // 快路：页面是 React 空壳，订单来自 mtop queryboughtlistV2；我们自己算 sign 直接请求。
        let fast = await TbFast.fetch(cookie: cookie)
        if !fast.orders.isEmpty {
            let note = String(format: "%@ · 用时 %.1f 秒", fast.note, Date().timeIntervalSince(started))
            return FetchOutcome(
                orders: fast.orders,
                httpStatus: 200,
                byteCount: 0,
                rawFileURL: payloadFile(for: .tb),
                note: note
            )
        }
        let fastFail = "；" + fast.note
        // 慢路：真渲染，兜底用。
        let slow = try await fetchWebOrders(
            platform: .tb,
            cookie: cookie,
            urls: [
                "https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm"
            ],
            seconds: 20,
            readyJS: "(document.body.innerText.match(/订单号/g) || []).length >= 2 ? '1' : '0'"
        )
        return FetchOutcome(
            orders: slow.orders,
            httpStatus: slow.httpStatus,
            byteCount: slow.byteCount,
            rawFileURL: slow.rawFileURL,
            note: slow.note + fastFail
        )
    }

    /// 诊断：直取 PC 列表页 HTML，原样落盘，顺便数一数 HTML 里有什么。
    private static func jdPCListDiagnostic(cookie: String) async -> String {
        let (status, html) = await JdDirect.fetchOrderListHTML(cookie: cookie)
        guard status == 200, !html.isEmpty else { return "；PC直取 HTTP\(status)" }
        try? html.data(using: .utf8)?.write(to: jdListHTMLFile(), options: .atomic)
        let text = HTMLTools.strip(html)
        try? text.data(using: .utf8)?.write(to: jdListTextFile(), options: .atomic)
        let keys = ["订单号", "orderId", "orderList", "order_list", "请登录", "我的订单", "待收货"]
        let counts = keys.map { $0 + "×" + String(JdDirect.occurrences(of: $0, in: html)) }.joined(separator: "·")
        return "；PC直取 \(html.count)字 HTML：\(counts)"
    }

    /// 京东：手机版 my.m.jd.com → 自动点「全部订单」→ 读页面文本。
    /// 这是 0.19.6/0.19.7 验证过能出 10 单的那条路（需要手机版登录的 pt_key）。
    static func jdListHTMLFile() -> URL { rawDirectory().appendingPathComponent("jd_list.html") }
    static func jdListTextFile() -> URL { rawDirectory().appendingPathComponent("jd_list.txt") }
    /// 电脑版订单页解析出的纯文本（排障时看这个就知道解析器哪儿不认）
    static func jdPCListFile() -> URL { rawDirectory().appendingPathComponent("jd_pc_list.txt") }

    /// 电脑版（thor/pin）订单页：先用 URLSession 直取 HTML，解析不到再让桌面槽渲染一遍。
    /// 只用 thor/pin 那套**独立会话**（桌面 UA），手机版 pt_key 被风控时它往往还活着。
    /// 结果不可信（落到登录页/错误页）就返回空数组，并在「电脑版列表」里写清看见了什么。
    private struct PcResult {
        var orders: [Order] = []
        var dump = ""
        var diag = ""
    }

    private static func jdPCRows(cookie: String) async -> PcResult {
        let (status, html) = await JdDirect.fetchOrderListHTML(cookie: cookie)
        // HTML 直取到的老版页面里常带 `orderid=…&PassKey=…` 的详情链接，先捡一遍
        JdPCLinks.harvest(from: html)
        var pcRows = JdPCList.parse(html: html)
        var pcSource = "HTML直取"
        var pcText = HTMLTools.strip(html)
        var renderNote = ""
        // 桌面渲染会连商品图一起取回来（JS 返回 {"t": 正文, "i": 图片URL}）
        var pcImgs: [String] = []
        // 订单号 → 商品图（渲染 JS 从订单卡片里爬出来的），按下标对图会错位
        var pcPics: [String: String] = [:]
        if pcRows.isEmpty {
            // 直取没解析到：可能是 JS 渲染版或者被踢回登录页，让桌面槽渲染一遍再试
            let rendered = await WebOrderFetcher.shared.jdPCListRender(cookieHeader: cookie)
            if rendered.hasPrefix("200|") {
                let body = String(rendered.dropFirst(4))
                if let data = body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    pcText = (obj["t"] as? String) ?? ""
                    pcImgs = (obj["i"] as? [String]) ?? []
                    pcPics = (obj["p"] as? [String: String]) ?? [:]
                    if let links = obj["l"] as? [String: String], !links.isEmpty {
                        JdPCLinks.save(links)
                    }
                    if let details = obj["d"] as? [String: String], !details.isEmpty {
                        JdPCLinks.save(details)
                    }
                } else {
                    pcText = body
                }
                pcRows = JdPCList.parse(text: pcText)
                pcSource = "桌面渲染"
            } else {
                renderNote = "【渲染失败】\(rendered)"
            }
        }
        // 电脑版这一路到底看见了什么，全部写进「调试 · 抓取文件 → 电脑版列表」那一份，
        // 免得又出现「只有一个数字、看不出问题在哪」的情况。
        // 关键词要数**渲染后的正文**：HTML 里订单是 JS 渲染的，数 HTML 永远是 0（0.36.15 就栽在这）。
        let keys = ["订单号", "请登录", "免费注册", "我的订单", "等待付款", "等待收货", "已完成", "验证"]
        let counts = keys.map { $0 + "×" + String(JdDirect.occurrences(of: $0, in: pcText)) }.joined(separator: "·")
        let loggedIn = !pcText.isEmpty && !pcText.contains("免费注册") && !pcText.contains("你好，请登录")
        var pcHeader = "【版本】\(Self.appVersion())\n【电脑版】HTML HTTP \(status) · \(html.count) 字 · \(counts)"
        pcHeader += "\n【登录态】" + (loggedIn ? "页面像已登录" : "页面显示未登录（请登录/免费注册）")
        pcHeader += "\n【来源】\(pcSource)"
        if !renderNote.isEmpty { pcHeader += "\n" + renderNote }
        if !pcImgs.isEmpty { pcHeader += "\n【图片 \(pcImgs.count) 张】" + String(pcImgs[0].prefix(120)) }
        if !pcText.isEmpty { pcHeader += "\n【正文 \(pcText.count) 字·开头 800】\n\(String(pcText.prefix(800)))" }
        if !pcRows.isEmpty {
            pcHeader += "\n【解析 \(pcRows.count) 条】"
                + pcRows.map { "\($0.orderNo)/\($0.statusRaw)/\(String($0.title.prefix(16)))" }.joined(separator: " ｜ ")
        }
        try? (pcHeader + "\n\n---- 正文全文 ----\n" + pcText)
            .data(using: .utf8)?.write(to: jdPCListFile(), options: .atomic)
        // 登录页/错误页也会解析出「1 条」，那种页面的特征是正文很短、压根没有「订单号」。
        // 真订单页哪怕只有一单，正文里一定出现「订单号」这三个字。
        let pcTrustworthy = !pcRows.isEmpty && (pcRows.count >= 2 || pcText.contains("订单号"))
        let orders = pcTrustworthy ? pcRows.enumerated().map { (index, row) -> Order in
            Order(id: Order.makeID(platform: .jd, orderNo: row.orderNo),
                  platform: .jd,
                  orderNo: row.orderNo,
                  title: row.title,
                  shopName: "京东",
                  amount: row.amount,
                  status: row.status,
                  statusRaw: row.statusRaw.isEmpty ? row.status.label : row.statusRaw,
                  orderTime: row.dateText,
                  logistics: "",
                  pickupCode: "",
                  imageURL: pcPics[row.orderNo] ?? (index < pcImgs.count ? pcImgs[index] : ""),
                  updatedAt: Date())
        } : []
        var out = PcResult()
        out.orders = orders
        out.dump = "【PC·\(pcSource)】" + pcHeader
            + (orders.isEmpty ? "\n【未采用】解析结果不可信" : "\n【备用】\(orders.count) 条")
        out.diag = "PC:HTTP\(status)/\(html.count)字/\(pcRows.count)条" + (orders.isEmpty ? "(未采用)" : "(备用)")
        return out
    }

    /// 京东：**只走电脑版**（`thor`/`pin` 那套独立会话）。
    /// 手机版（`pt_key`）那条路 2026-11-19 整条删掉：实测会话 1.5～3 小时就失效
    /// （14:53→17:48、19:34→21:00），每次都要重登 + 过滑块/短信验证，代价远大于收益。
    /// 代价是电脑版只列「近 3 个月」；对「在途单/取件码」够用，库里的历史单按订单号补在后面。
    /// 电脑版列表页里带出来的「订单号 → 订单详情 URL」。
    /// 详情页 URL 带签名/时间戳，不能自己拼，只能从列表页的 <a href> 里捡；
    /// 刷新时顺手存下来，点「物流详情」直接用，省掉自己猜 URL 那一步。
    enum JdPCLinks {
        private static let key = "jd_pc_links"

        static func save(_ map: [String: String]) {
            guard !map.isEmpty else { return }
            var merged = all()
            for (k, v) in map { merged[k] = v }
            UserDefaults.standard.set(merged, forKey: key)
        }

        static func all() -> [String: String] {
            (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        }

        static func url(for orderNo: String) -> String? {
            all()[orderNo]
        }

        /// 老版订单页的详情链接直接写在 HTML 里（`…item.action?orderid=123&PassKey=ABCD…`），
        /// 渲染后的 DOM 里不一定还有，所以两边都扫一遍补进表里。
        static func harvest(from html: String) {
            guard !html.isEmpty else { return }
            let pattern = #"(?:orderid|orderId|deal_id)=(\d{8,25})&(?:amp;)?PassKey=([0-9A-Fa-f]{16,64})"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = html as NSString
            var found: [String: String] = [:]
            re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 2 else { return }
                let no = ns.substring(with: match.range(at: 1))
                let passKey = ns.substring(with: match.range(at: 2))
                found[no] = "https://details.jd.com/normal/item.action?orderid=\(no)&PassKey=\(passKey)"
            }
            if !found.isEmpty { save(found) }
        }
    }
    private static func fetchJd() async throws -> FetchOutcome {
        let started = Date()
        var dump: [String] = []
        var stampText = "未知"
        if let at = CookieStore.savedAtPc(for: .jd) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            stampText = formatter.string(from: at)
        }
        dump.append("【版本】\(Self.appVersion())\n【通道】京东电脑版（thor/pin）\n【凭证】存于 \(stampText)")
        guard let pcCookie = CookieStore.loadPc(for: .jd), pcCookie.contains("thor=") else {
            _ = write(dump.joined(separator: "\n\n"), to: jdInPageFile())
            throw FetchError.note("京东现在走电脑版登录：点「京东 → 电脑版登录」，用京东 App 扫码登一次就好")
        }
        let pc = await jdPCRows(cookie: pcCookie)
        dump.append(pc.dump)
        guard !pc.orders.isEmpty else {
            _ = write(dump.joined(separator: "\n\n"), to: jdInPageFile())
            throw FetchError.note("京东电脑版已登录，但订单页里没解析到订单（\(pc.diag)）—— 发「调试 · 抓取文件 → 京东 → 电脑版列表」给我")
        }
        // 电脑版只列近 3 个月，库里以前抓到的历史单不要丢：新结果打头，老单按订单号补在后面。
        let known = Set(pc.orders.map { $0.orderNo })
        let history = OrderStore.shared.all().filter { $0.platform == .jd && !known.contains($0.orderNo) }
        let merged = pc.orders + history
        let cost = String(format: "%.1f", Date().timeIntervalSince(started))
        dump.append("【采用电脑版】\(pc.orders.count) 条（主路）＋历史 \(history.count) 条")
        _ = write(dump.joined(separator: "\n\n"), to: jdInPageFile())
        return FetchOutcome(
            orders: merged,
            httpStatus: 200,
            byteCount: merged.count,
            rawFileURL: jdPCListFile(),
            note: "京东电脑版 \(pc.orders.count) 条" + (history.isEmpty ? "" : "＋历史 \(history.count) 条") + "· 用时 \(cost) 秒",
            payloadJSON: "",
            authoritative: true
        )
    }
    /// 试一次页内重放；成功就拼成 FetchOutcome 返回，失败只往 diag 里记一句
    private static func jdReplayOutcome(slot: String, label: String, url: String, saved: JdFast.Saved,
                                        timeoutMS: Double, started: Date, diag: inout [String]) async -> FetchOutcome? {
        let raw = await WebOrderFetcher.shared.inPageReplay(
            slot: slot,
            url: url,
            method: saved.method ?? "GET",
            headers: JdFast.safeHeaders(saved.headers, body: saved.body ?? ""),
            body: saved.body ?? "",
            timeoutMS: timeoutMS
        )
        return jdOutcome(raw: raw, label: label, url: url, started: started, diag: &diag)
    }

    /// 把一次重放结果（"status|body" 那种）变成订单；失败记一句诊断返回 nil
    private static func jdOutcome(raw: String, label: String, url: String, started: Date,
                                  diag: inout [String]) -> FetchOutcome? {
        diag.append(label + replayBrief(raw))
        guard raw.hasPrefix("200|") else { return nil }
        let body = String(raw.dropFirst(4))
        guard body.contains("orderList") else { return nil }
        let wrapped = "[{\"u\":" + JdFast.jsonQuotedPublic(url) + ",\"b\":" + JdFast.jsonQuotedPublic(body) + "}]"
        let orders = TaobaoJdParser.parse(platform: .jd, text: "", payloadJSON: wrapped)
        guard !orders.isEmpty else {
            diag.append("解析0条")
            return nil
        }
        let cost = String(format: "%.1f", Date().timeIntervalSince(started))
        _ = write(wrapped, to: payloadFile(for: .jd))
        return FetchOutcome(
            orders: orders,
            httpStatus: 200,
            byteCount: body.count,
            rawFileURL: payloadFile(for: .jd),
            note: "京东页内直取 \(orders.count) 条（\(label)）· 用时 \(cost) 秒",
            payloadJSON: wrapped,
            authoritative: true
        )
    }

    /// 把页内重放的原始返回压成一行诊断，塞进 note
    private static func replayBrief(_ raw: String) -> String {
        if raw.isEmpty { return " 空返回" }
        if raw.hasPrefix("NOPAGE") { return " 没页面" }
        if raw.hasPrefix("TIMEOUT") { return " 超时" }
        if raw.hasPrefix("ERR") { return " " + String(raw.dropFirst(4)) }
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return " 格式异常" }
        let body = String(parts[1])
        // 能解析成 JSON 就报出键名，比只给前 40 字有信息量（例如 code0 的空壳长什么样）
        var shape = body.contains("orderList") ? "有orderList" : ""
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            shape = "J{" + obj.keys.sorted().prefix(5).joined(separator: ",") + "}"
            if let inner = obj["body"] as? [String: Any] {
                shape += "body{" + inner.keys.sorted().prefix(5).joined(separator: ",") + "}"
            }
        } else if shape.isEmpty {
            shape = "非JSON"
        }
        let head = String(body.prefix(26)).replacingOccurrences(of: "\n", with: " ")
        return " HTTP\(parts[0])/\(body.count)字/\(shape)「\(head)」"
    }

    /// 淘宝 / 京东：都是前端渲染，用同一个 WebView 抓包路线，只是地址和解析器不同。
    private static func fetchWebOrders(platform: Platform, cookie: String, urls: [String], seconds: Double, readyJS: String? = nil, clickTexts: [String] = [], clickReadyJS: String? = nil) async throws -> FetchOutcome {
        let started = Date()
        // 统一用真机版本的 Safari UA（见 UserAgent 文件头注释）
        let mobileUA = UserAgent.iOS
        let desktopUA = UserAgent.macOS

        // 每个地址先用手机 UA 试；PC 版地址再补一次桌面 UA
        // 淘宝的 H5 订单页没有下单时间和快递公司，PC 版（buyertrade）才有；所以 PC 版排前面。
        var plan: [(String, String)] = []
        if platform == .tb {
            for url in urls where url.contains("buyertrade") || url.contains("trade/itemlist") {
                plan.append((url, desktopUA))
                plan.append((url, mobileUA))
            }
            for url in urls where !(url.contains("buyertrade") || url.contains("trade/itemlist")) {
                plan.append((url, mobileUA))
            }
        } else if platform == .jd {
            for url in urls where !url.contains("order.jd.com") {
                plan.append((url, mobileUA))
            }
            for url in urls where url.contains("order.jd.com") {
                plan.append((url, mobileUA))
                plan.append((url, desktopUA))
            }
        } else {
            plan = urls.map { ($0, mobileUA) }
            for url in urls where url.contains("buyertrade") || url.contains("trade/itemlist") {
                plan.append((url, desktopUA))
            }
        }

        var capture: WebOrderFetcher.Capture?
        var orders: [Order] = []
        var tried: [String] = []

        for (raw, ua) in plan {
            guard let url = URL(string: raw) else { continue }
            let one = try await WebOrderFetcher.shared.capture(
                platform: platform,
                urls: [url],
                cookieHeader: cookie,
                seconds: seconds,
                clickTabs: false,
                clickTexts: clickTexts,
                minWait: 0,
                strict: true,
                scroll: true,
                userAgent: ua,
                readyJS: readyJS,
                slot: "list-\(platform.rawValue)",
                clickReadyJS: clickReadyJS
            )
            tried.append(contentsOf: one.tried)
            let parsed = TaobaoJdParser.parse(platform: platform, text: one.text, payloadJSON: one.payloadJSON, html: one.html)
            if parsed.count > orders.count || capture == nil {
                capture = one
                orders = parsed
            }
            if !orders.isEmpty {
                orders = Self.applyDigest(orders, digest: one.digest)
                break
            }
        }

        guard let capture else { throw FetchError.badURL }

        if platform == .jd, capture.title.contains("验证") || capture.text.contains("验证一下，购物无忧") || capture.text.contains("请完成验证") {
            throw FetchError.note("京东要人机验证了：在「平台」页点「京东」打开网页，手动把验证滑过去，再回来刷新。")
        }

        if !capture.cookieHeader.isEmpty, capture.cookieHeader != cookie,
           CookieStore.hasLogin(capture.cookieHeader, platform: platform) {
            CookieStore.save(capture.cookieHeader, for: platform)
        }

        var info = CaptureInfo()
        info.textChars = capture.text.count
        info.payloadChars = capture.payloadJSON.count
        info.pageTitle = capture.title
        info.attempts = tried
        info.snippet = String(capture.text.prefix(160))
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pageErr = write(capture.text, to: pageFile(for: platform))
        let payloadErr = write(capture.payloadJSON, to: payloadFile(for: platform))
        if platform == .tb {
            let reqs = TaobaoJdParser.extractMtopRequests(payloadJSON: capture.payloadJSON) ?? ""
            _ = write(reqs, to: tbListRequestsFile(for: .tb))
        }
        // 京东电脑版整页 1MB 以上，只留前 40 万字，省内存也够排查
        var htmlToWrite = capture.html
        if platform == .jd, htmlToWrite.count > 400_000 {
            htmlToWrite = String(htmlToWrite.prefix(400_000)) + "\n<!-- 截断 -->"
        }
        let htmlErr = write(htmlToWrite, to: htmlFile(for: platform))
        let digestErr = write(capture.digest, to: digestFile(for: platform))
        // 京东：如果这次抓包没能进存档，就在这个还活着的页面里手挑一条订单请求验一次，
        // 至少能回答「页内重放这条路本身通不通」。存档成功的话由 fetchJd 统一验，别重复花时间。
        var jdProbeLine = ""
        if platform == .jd, JdFast.loadAll().isEmpty, let req = JdDirect.findRequest(in: capture.payloadJSON) {
            let raw = await WebOrderFetcher.shared.inPageReplay(
                url: JdFast.refreshT(req.url),
                method: req.method,
                headers: JdFast.safeHeaders(req.headers, body: req.body ?? ""),
                body: req.body ?? ""
            )
            jdProbeLine = "；页内验" + replayBrief(raw)
        }
        info.writeError = [pageErr, payloadErr, htmlErr, digestErr].compactMap { $0 }.joined(separator: " / ")

        if let data = capture.payloadJSON.data(using: .utf8),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            info.entryCount = entries.count
            var largest = ""
            for entry in entries {
                let path = urlPath(entry["u"] as? String ?? "")
                let body = entry["b"] as? String ?? ""
                if !path.isEmpty, !info.urls.contains(path) { info.urls.append(path) }
                if !path.isEmpty, info.entrySizes.count < 8 {
                    info.entrySizes.append("\(shortPath(path)) · \(body.count / 1024) KB")
                }
                if body.count > largest.count { largest = body }
            }
            info.urls = Array(info.urls.prefix(8))
            info.largestBody = largest
        }

        lastCapture = info

        if capture.landedOnLogin {
            throw FetchError.note("\(platform.name) 的登录态失效了，点「重新登录」，登录完再刷新订单。")
        }

        var note = "落点 \(shortPath(capture.finalURL))「\(capture.title.isEmpty ? "无标题" : capture.title)」"
        note += info.entryCount > 0
            ? " · 抓到 \(info.entryCount) 个接口响应，解析出 \(orders.count) 条订单"
            : " · 没抓到接口响应，页面文本 \(info.textChars) 字"
        if orders.isEmpty, !info.snippet.isEmpty {
            note += "；页面开头：\(info.snippet.prefix(50))"
        }
        if !info.writeError.isEmpty { note += "；文件写入失败：\(info.writeError)" }
        if platform == .jd {
            let hasThor = capture.headerCookieNames.contains("thor") ? "有" : "无"
            let storeThor = capture.storeCookieNames.contains("thor") ? "有" : "无"
            note += "；凭证 \(capture.headerCookieNames.count) 个/thor" + hasThor + "；WebView \(capture.storeCookieNames.count) 个/thor" + storeThor
            // 凭证是什么时候存的：会话失效时一眼能对上时间（京东 web 会话寿命有限）
            if let at = CookieStore.savedAt(for: .jd) {
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd HH:mm"
                note += "·存于" + formatter.string(from: at)
            }
        }
        note += jdProbeLine
        note += String(format: " · 用时 %.1f 秒", Date().timeIntervalSince(started))

        return FetchOutcome(
            orders: orders,
            httpStatus: 200,
            byteCount: info.textChars + info.payloadChars,
            rawFileURL: payloadFile(for: platform),
            note: note,
            payloadJSON: capture.payloadJSON
        )
    }

    /// 判断一段响应是不是「订单列表 JSON」（不在里面找 order_sn，因为空列表也是合法结果）
    private static func fastOk(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["orders"] is [Any]
    }

    private static func fetchPinduoduo(cookie: String) async throws -> FetchOutcome {
        let started = Date()

        // 快路：之前抓到过 order_list 请求，直接重放，不开 WebView。
        // 页面会发好几条（默认/待发货/待收货），有的返回空列表，所以逐份试。
        var fastNote = "快路："
        // 快路零：页面还开着的话，直接在页面里把候选请求重放一遍，挑出「有进行中订单」的那份
        if !cookie.isEmpty {
            let replay = await WebOrderFetcher.shared.inPageReplayBodies(slot: "pdd", urlContains: "order_list")
            if replay.bodies.isEmpty {
                fastNote += "页内重放不可用（\(replay.note)）｜"
            } else {
                var chosen: (orders: [Order], payload: String, size: Int)?
                for body in replay.bodies {
                    let payload = PddFast.payloadJSON(url: "https://mobile.pinduoduo.com/proxy/api/api/aristotle/order_list_v4", body: body)
                    var parsed = attachLogistics(PinduoduoParser.parse(text: "", payloadJSON: payload), payloadJSON: payload)
                    let hasActive = parsed.contains { $0.status == .paid || $0.status == .shipped }
                    if hasActive {
                        chosen = (parsed, payload, body.count)
                        break
                    }
                    if chosen == nil, !parsed.isEmpty {
                        chosen = (parsed, payload, body.count)
                    }
                }
                if let picked = chosen {
                    let hasActive = picked.orders.contains { $0.status == .paid || $0.status == .shipped }
                    if hasActive {
                        let enriched = await enrichShipping(picked.orders, cookie: cookie)
                        let pickupN = enriched.filter { !$0.pickupCode.isEmpty }.count
                        let note0 = String(format: "页内重放 %d 条订单，取件码 %d 单 · 用时 %.1f 秒",
                                           enriched.count, pickupN, Date().timeIntervalSince(started))
                        return FetchOutcome(orders: enriched, httpStatus: 200, byteCount: picked.size,
                                            rawFileURL: self.payloadFile(for: .pdd), note: note0,
                                            payloadJSON: picked.payload, authoritative: true)
                    }
                    fastNote += "页内重放 \(picked.orders.count) 条但没有进行中的订单｜"
                }
            }
        }
        if cookie.isEmpty {
            fastNote += "没有 cookie"
        } else {
            let saves = PddFast.loadAll()
            if saves.isEmpty {
                fastNote += "无存档"
            } else {
                for (index, saved) in saves.enumerated() {
                    guard let result = await PddFast.replay(saved, cookie: cookie) else {
                        fastNote += (fastNote.count > 3 ? "｜" : "") + "第 \(index + 1) 份重放失败（网络）"
                        continue
                    }
                    if result.status != 200 {
                        fastNote += (fastNote.count > 3 ? "｜" : "") + "第 \(index + 1) 份重放 HTTP \(result.status)"
                        continue
                    }
                    _ = self.write(result.text, to: PddFast.responseFile())
                    if result.text.contains("harmony_empty_height_and_back_refresh") {
                        // 这是页面用来「确认有没有新数据」的探针请求，永远返回空，跳过
                        fastNote += (fastNote.count > 3 ? "｜" : "") + "第 \(index + 1) 份是探针请求"
                        continue
                    }
                    guard fastOk(result.text) else {
                        fastNote += (fastNote.count > 3 ? "｜" : "") + "第 \(index + 1) 份重放 \(result.text.count) 字节但不是订单 JSON"
                        continue
                    }
                    let payload = PddFast.payloadJSON(url: saved.url, body: result.text)
                    var fastOrders = attachLogistics(PinduoduoParser.parse(text: "", payloadJSON: payload), payloadJSON: payload)
                    // 0 条也算有效结果（比如东西全取完了，确实没有进行中的订单），
                    // 否则「取完快递」之后每次刷新都会掉回 WebView 的 7 秒。
                    let hasActive = fastOrders.contains { $0.status == .paid || $0.status == .shipped }
                    if !fastOrders.isEmpty && !hasActive {
                        fastNote += (fastNote.count > 3 ? "｜" : "") + "第 \(index + 1) 份返回 \(fastOrders.count) 条但都不是待发货/待收货"
                        continue
                    }
                    fastOrders = await enrichShipping(fastOrders, cookie: cookie)
                    _ = self.write(payload, to: self.payloadFile(for: .pdd))
                    let pickupCount = fastOrders.filter { !$0.pickupCode.isEmpty }.count
                    let note = String(format: "直连重放 %d 条订单，取件码 %d 单，用了第 %d/%d 份存档 · 用时 %.1f 秒",
                                      fastOrders.count, pickupCount, index + 1, saves.count,
                                      Date().timeIntervalSince(started))
                    return FetchOutcome(
                        orders: fastOrders,
                        httpStatus: 200,
                        byteCount: result.text.count,
                        rawFileURL: self.payloadFile(for: .pdd),
                        note: note,
                        payloadJSON: payload,
                        authoritative: true
                    )
                }
            }
        }

        let candidates = [
            "https://mobile.pinduoduo.com/order.html",
            "https://mobile.yangkeduo.com/orders.html"
        ].compactMap { URL(string: $0) }

        guard !candidates.isEmpty else { throw FetchError.badURL }

        let capture = try await WebOrderFetcher.shared.capture(platform: .pdd, urls: candidates, cookieHeader: cookie, seconds: 15, slot: "pdd")

        // 平台会在打开页面时轮换登录 token，抓完把最新的写回钥匙串，下次就不用重新登录
        if !capture.cookieHeader.isEmpty, CookieStore.hasLogin(capture.cookieHeader, platform: .pdd),
           capture.cookieHeader != cookie {
            CookieStore.save(capture.cookieHeader, for: .pdd)
        }

        var info = CaptureInfo()
        info.textChars = capture.text.count
        info.payloadChars = capture.payloadJSON.count
        info.pageTitle = capture.title
        info.attempts = capture.tried
        info.snippet = String(capture.text.prefix(200))
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pageErr = write(capture.text, to: pageFile(for: .pdd))
        let payloadErr = write(capture.payloadJSON, to: payloadFile(for: .pdd))
        info.writeError = [pageErr, payloadErr].compactMap { $0 }.joined(separator: " / ")

        if let data = capture.payloadJSON.data(using: .utf8),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            info.entryCount = entries.count
            var largest = ""
            for entry in entries {
                let path = urlPath(entry["u"] as? String ?? "")
                let body = entry["b"] as? String ?? ""
                if !path.isEmpty, !info.urls.contains(path) { info.urls.append(path) }
                if !path.isEmpty, info.entrySizes.count < 8 {
                    info.entrySizes.append("\(shortPath(path)) · \(body.count / 1024) KB")
                }
                if body.count > largest.count { largest = body }
            }
            info.urls = Array(info.urls.prefix(8))
            info.largestBody = largest
        }

        // 抓不到东西时，试三种 UA 直接请求一次，看看服务端渲染路线有没有可能
        if info.entryCount == 0, info.textChars < 300 {
            info.uaProbe = await probeUserAgents(cookie: capture.cookieHeader.isEmpty ? cookie : capture.cookieHeader, url: candidates[0])
        }
        lastCapture = info

        if capture.landedOnLogin {
            throw FetchError.note("拼多多的登录态失效了。点「重新登录」时建议用扫码登录（不会把手机 App 顶下线），登录完再刷新订单。")
        }

        try? capture.cardsJSON.data(using: .utf8)?.write(to: cardsFile(for: .pdd), options: .atomic)
        var orders = attachLogistics(PinduoduoParser.parse(text: capture.text, payloadJSON: capture.payloadJSON), payloadJSON: capture.payloadJSON)
        // 列表卡片上直接带着取件码 / 最新物流，不用再点进详情页
        orders = PinduoduoParser.applyCards(orders, cardsJSON: capture.cardsJSON)
        // 列表页上没有取件码，直接按订单号问物流接口（只问还在路上的那几单）
        orders = await enrichShipping(orders, cookie: capture.cookieHeader.isEmpty ? cookie : capture.cookieHeader)

        // 把这次抓到的 order_list 请求存起来，下次直接用 URLSession 重放
        _ = PddFast.save(fromPayload: capture.payloadJSON)

        let pickupCount = orders.filter { !$0.pickupCode.isEmpty }.count
        var note: String
        if !fastNote.isEmpty { fastNote = "；" + fastNote }
        note = info.entryCount > 0
            ? "抓到 \(info.entryCount) 个接口响应，解析出 \(orders.count) 条订单，取件码 \(pickupCount) 单"
            : "没抓到接口响应，页面文本 \(info.textChars) 字"
        if orders.isEmpty, !info.snippet.isEmpty { note += "；页面开头：\(info.snippet.prefix(60))" }
        if !info.writeError.isEmpty { note += "；文件写入失败：\(info.writeError)" }
        note += fastNote
        note += String(format: " · 用时 %.1f 秒", Date().timeIntervalSince(started))

        return FetchOutcome(
            orders: orders,
            httpStatus: 200,
            byteCount: info.textChars + info.payloadChars,
            rawFileURL: payloadFile(for: .pdd),
            note: note
        )
    }

    /// 直接请求同一个订单页，换三种 UA，看谁能让服务端直接吐出订单
    private static func probeUserAgents(cookie: String, url: URL) async -> [String] {
        let uas: [(String, String)] = [
            ("Safari", UserAgent.iOS),
            ("微信", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49(0x18003133) NetType/WIFI Language/zh_CN"),
            ("拼多多App", "Pinduoduo/6.90.0 (iPhone; iOS 17.0; Scale/3.00)")
        ]
        var out: [String] = []
        for (name, ua) in uas {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                let hits = body.components(separatedBy: "订单号").count - 1
                out.append("\(name)：HTTP \(code)，\(data.count / 1024) KB，订单号 ×\(hits)")
            } catch {
                out.append("\(name)：请求失败")
            }
        }
        return out
    }

    /// 把物流接口里那句「运输中…」挂到对应的订单上
    private static func attachLogistics(_ orders: [Order], payloadJSON: String) -> [Order] {
        guard !orders.isEmpty,
              let data = payloadJSON.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return orders }

        var snSet = Set<String>()
        var info = ""
        for entry in entries {
            let u = entry["u"] as? String ?? ""
            guard let body = entry["b"] as? String,
                  let bodyData = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            else { continue }
            if u.contains("track/status"), let list = obj["result_list"] as? [[String: Any]] {
                for item in list {
                    if let sn = item["order_sn"] as? String { snSet.insert(sn) }
                }
            }
            if u.contains("track/latest"),
               let result = obj["result"] as? [String: Any],
               let text = result["info"] as? String, !text.isEmpty {
                info = text
            }
        }

        guard !info.isEmpty, !snSet.isEmpty else { return orders }
        return orders.map { order in
            guard snSet.contains(order.orderNo) else { return order }
            var copy = order
            copy.logistics = String(info.prefix(80))
            return copy
        }
    }

    /// 对还在运输中的订单补物流信息（快递公司、最新轨迹、取件码）。
    private static func enrichShipping(_ orders: [Order], cookie: String) async -> [Order] {
        guard !cookie.isEmpty else { return orders }
        let targets = Array(orders.indices.filter { orders[$0].status == .shipped && orders[$0].pickupCode.isEmpty }.prefix(3))
        guard !targets.isEmpty else { return orders }

        var result = orders
        // 三单并发问物流接口，不再一单一单排队
        await withTaskGroup(of: (Int, ShippingClient.Info?).self) { group in
            for index in targets {
                let sn = orders[index].orderNo
                group.addTask {
                    (index, await ShippingClient.fetch(orderNo: sn, cookieHeader: cookie))
                }
            }
            for await (index, info) in group {
                guard let info else { continue }
                if !info.carrier.isEmpty { result[index].carrier = info.carrier }
                if !info.pickup.isEmpty { result[index].pickupCode = info.pickup }
                if !info.logistics.isEmpty { result[index].logistics = info.logistics }
            }
        }
        return result
    }

    private static func shortPath(_ path: String) -> String {
        var s = path
        if s.count > 46 { s = "…" + String(s.suffix(44)) }
        return s
    }

    private static func write(_ text: String, to url: URL) -> String? {
        // JS 字符串里可能带孤立代理项，utf8 编码会直接返回 nil，退回 utf16
        let data = text.data(using: .utf8) ?? text.data(using: .utf16)
        guard let data else { return "编码失败" }
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func urlPath(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return String(raw.prefix(80)) }
        let path = url.path
        if path.isEmpty { return url.host ?? "" }
        return "\(url.host ?? "")\(path)"
    }

    /// 淘宝 PC 订单页的文字里没有图片和下单时间，只能从 DOM 摘要按纵向顺序补进去。
    private static func applyDigest(_ orders: [Order], digest: String) -> [Order] {
        guard let data = digest.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !orders.isEmpty else { return orders }

        let images = (object["imgs"] as? [[String: Any]] ?? [])
            .compactMap { $0["s"] as? String }
            .filter { !$0.isEmpty }
        let times = (object["times"] as? [[String: Any]] ?? [])
            .compactMap { $0["t"] as? String }
            .filter { !$0.isEmpty }

        var out = orders
        for index in out.indices {
            if index < images.count, out[index].imageURL.isEmpty {
                out[index].imageURL = images[index]
            }
            if index < times.count, out[index].orderTime.isEmpty {
                out[index].orderTime = times[index]
            }
        }
        return out
    }

    /// 写进调试文件头，免得「这包是哪一版」都要靠猜
    static func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v)(\(b))"
    }

    /// 调试用的可分享文件：每个平台只列自己的那几份，且只返回真实存在的
    static func debugFiles(for platform: Platform) -> [DebugFile] {
        var list: [DebugFile] = [
            DebugFile(id: "page-\(platform.rawValue)", label: "页面文本", url: pageFile(for: platform)),
            DebugFile(id: "html-\(platform.rawValue)", label: "网页源码", url: htmlFile(for: platform)),
            DebugFile(id: "payload-\(platform.rawValue)", label: "接口数据", url: payloadFile(for: platform)),
            DebugFile(id: "digest-\(platform.rawValue)", label: "图片时间", url: digestFile(for: platform))
        ]
        switch platform {
        case .pdd:
            list.append(DebugFile(id: "pdddetail-\(platform.rawValue)", label: "详情接口", url: detailPayloadFile(for: platform)))
            list.append(DebugFile(id: "pddfast-\(platform.rawValue)", label: "直连响应", url: PddFast.responseFile()))
        case .tb:
            list.append(DebugFile(id: "tbdetail-\(platform.rawValue)", label: "订单详情页", url: tbDetailFile(for: platform)))
            list.append(DebugFile(id: "tblistreq-\(platform.rawValue)", label: "列表请求", url: tbListRequestsFile(for: platform)))
            list.append(DebugFile(id: "tblogihtml-\(platform.rawValue)", label: "物流页源码", url: tbLogisticsHTMLFile(for: platform)))
            list.append(DebugFile(id: "tbrawhtml-\(platform.rawValue)", label: "物流直连HTML", url: tbRawHTMLFile(for: platform)))
        case .jd:
            list.append(DebugFile(id: "jdarchive", label: "请求存档", url: JdFast.file()))
            list.append(DebugFile(id: "jddetail-\(platform.rawValue)", label: "订单详情页", url: jdDetailFile(for: platform)))
            list.append(DebugFile(id: "jdreq-\(platform.rawValue)", label: "直连请求", url: JdDirect.requestFile()))
            list.append(DebugFile(id: "jdinpage", label: "页内直取", url: jdInPageFile()))
            list.append(DebugFile(id: "jdpc", label: "电脑版列表", url: jdPCListFile()))
            list.append(DebugFile(id: "jdlisthtml", label: "列表HTML", url: jdListHTMLFile()))
            list.append(DebugFile(id: "jdlisttext", label: "列表文本", url: jdListTextFile()))
        }
        return list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

}

struct DebugFile: Identifiable {
    let id: String
    let label: String
    let url: URL
}
