import Foundation

struct FetchOutcome {
    var orders: [Order]
    var httpStatus: Int
    var byteCount: Int
    var rawFileURL: URL?
    var note: String
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
    static func tbDetailFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("tb_detail_\(platform.rawValue).txt")
    }

    static func fetch(platform: Platform) async throws -> FetchOutcome {
        guard let cookie = CookieStore.load(for: platform), !cookie.isEmpty else {
            throw FetchError.noCookie
        }
        switch platform {
        case .pdd:
            return try await fetchPinduoduo(cookie: cookie)
        case .tb:
            return try await fetchTaobao(cookie: cookie)
        case .jd:
            return try await fetchJd(cookie: cookie)
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
        try await fetchWebOrders(
            platform: .tb,
            cookie: cookie,
            urls: [
                "https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm"
            ],
            seconds: 16
        )
    }

    private static func fetchJd(cookie: String) async throws -> FetchOutcome {
        try await fetchWebOrders(
            platform: .jd,
            cookie: cookie,
            urls: [
                "https://home.m.jd.com/myOrders/myOrders.action",
                "https://m.jd.com/order/orderList.action"
            ],
            seconds: 22
        )
    }

    /// 淘宝 / 京东：都是前端渲染，用同一个 WebView 抓包路线，只是地址和解析器不同。
    private static func fetchWebOrders(platform: Platform, cookie: String, urls: [String], seconds: Double) async throws -> FetchOutcome {
        let started = Date()
        let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

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
                minWait: 10,
                strict: true,
                scroll: true,
                userAgent: ua
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
        let htmlErr = write(capture.html, to: htmlFile(for: platform))
        let digestErr = write(capture.digest, to: digestFile(for: platform))
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
        note += String(format: " · 用时 %.1f 秒", Date().timeIntervalSince(started))

        return FetchOutcome(
            orders: orders,
            httpStatus: 200,
            byteCount: info.textChars + info.payloadChars,
            rawFileURL: payloadFile(for: platform),
            note: note
        )
    }

    private static func fetchPinduoduo(cookie: String) async throws -> FetchOutcome {
        let started = Date()
        let candidates = [
            "https://mobile.pinduoduo.com/order.html",
            "https://mobile.yangkeduo.com/orders.html"
        ].compactMap { URL(string: $0) }

        guard !candidates.isEmpty else { throw FetchError.badURL }

        let capture = try await WebOrderFetcher.shared.capture(platform: .pdd, urls: candidates, cookieHeader: cookie, seconds: 15)

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

        let pickupCount = orders.filter { !$0.pickupCode.isEmpty }.count
        var note = info.entryCount > 0
            ? "抓到 \(info.entryCount) 个接口响应，解析出 \(orders.count) 条订单，取件码 \(pickupCount) 单"
            : "没抓到接口响应，页面文本 \(info.textChars) 字"
        if orders.isEmpty, !info.snippet.isEmpty { note += "；页面开头：\(info.snippet.prefix(60))" }
        if !info.writeError.isEmpty { note += "；文件写入失败：\(info.writeError)" }
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
            ("Safari", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"),
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

    /// 调试用的可分享文件（不存在的也列出来，由界面显示「未生成」）
    static func debugFiles(for platform: Platform) -> [DebugFile] {
        [
            DebugFile(id: "page-\(platform.rawValue)", label: "\(platform.name) · 页面文本", url: pageFile(for: platform)),
            DebugFile(id: "payload-\(platform.rawValue)", label: "\(platform.name) · 接口数据", url: payloadFile(for: platform)),
            DebugFile(id: "raw-\(platform.rawValue)", label: "\(platform.name) · 旧版原始页面", url: latestRawFile(for: platform)),
            DebugFile(id: "detail-\(platform.rawValue)", label: "\(platform.name) · 详情接口", url: detailPayloadFile(for: platform)),
            DebugFile(id: "cards-\(platform.rawValue)", label: "\(platform.name) · 列表卡片", url: cardsFile(for: platform)),
            DebugFile(id: "html-\(platform.rawValue)", label: "\(platform.name) · 网页源码", url: htmlFile(for: platform)),
            DebugFile(id: "tblogi-\(platform.rawValue)", label: "\(platform.name) · 物流接口", url: tbLogisticsFile(for: platform)),
            DebugFile(id: "digest-\(platform.rawValue)", label: "\(platform.name) · 图片时间", url: digestFile(for: platform)),
            DebugFile(id: "tbdetail-\(platform.rawValue)", label: "\(platform.name) · 订单详情页", url: tbDetailFile(for: platform)),
            DebugFile(id: "resources-\(platform.rawValue)", label: "\(platform.name) · 资源地址", url: resourcesFile(for: platform)),
            DebugFile(id: "tblogihtml-\(platform.rawValue)", label: "\(platform.name) · 物流页源码", url: tbLogisticsHTMLFile(for: platform)),
            DebugFile(id: "resourcesdetail-\(platform.rawValue)", label: "\(platform.name) · 详情页资源", url: resourcesDetailFile(for: platform))
        ]
    }
}

struct DebugFile: Identifiable {
    let id: String
    let label: String
    let url: URL
}
