import Foundation

/// 京东：把手机版订单列表页发出的那条已签名请求（URL + 方法 + 请求头 + 请求体）整条存下来，
/// 下次在同一个站点的页面里原样重放一次 —— cookie、UA、设备指纹、sign 全都由页面自己带，
/// 我们只负责“把原来那条请求再发一遍”。
///
/// 和拼多多 PddFast 的区别：拼多多的签名在 URL 里，URLSession 直连就行；
/// 京东的 sign 在混淆 JS 里（JdDirect 试过 URLSession 重放，稳定报 601），必须借页面之手发。
enum JdFast {
    struct Saved: Codable {
        var url: String
        var headers: [String: String]
        var savedAt: TimeInterval
        /// 下面三个是 0.36.1 加的，老存档没有也能解码
        var method: String?
        var body: String?
        /// 这条存档上一次重放拿到了多少条订单（0 表示还没验证过）
        var hit: Int?
    }

    static func file() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("jd_order_requests.json")
    }

    static func loadAll() -> [Saved] {
        guard let data = try? Data(contentsOf: file()),
              let list = try? JSONDecoder().decode([Saved].self, from: data) else { return [] }
        return list
    }

    static func saveAll(_ list: [Saved]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: file(), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file())
    }

    static func last() -> Saved? { loadAll().last }

    /// 最近一条存档的 URL（兼容老调用）
    static func lastURL() -> String? { loadAll().last?.url }

    /// 存档多久以前的（分钟）
    static func ageMinutes() -> Int {
        guard let last = loadAll().last else { return -1 }
        return Int((Date().timeIntervalSince1970 - last.savedAt) / 60)
    }

    /// 这条存档能不能信：刚存下不久，而且上次重放确实拿到过订单。
    /// 依据 0.36.3 实测：两小时前存下的 URL 重放回来是 code 0 的空壳，
    /// 说明 URL 里的 x-api-eid-token / 会话参数是有时效的，不是刷新一下 t 就能复活。
    static func isTrusted(maxAgeMinutes: Int = 12) -> Bool {
        guard let last = loadAll().last else { return false }
        if last.hit != 1 { return false }
        return Int(Date().timeIntervalSince1970 - last.savedAt) / 60 <= maxAgeMinutes
    }

    /// 记一次重放结果（成功/失败），下次据此判断还要不要走快路
    static func markHit(_ ok: Bool) {
        var list = loadAll()
        guard !list.isEmpty else { return }
        list[list.count - 1].hit = ok ? 1 : 0
        saveAll(list)
    }

    // MARK: - 存档

    private static func entries(_ payloadJSON: String) -> [[String: Any]]? {
        guard let data = payloadJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr
    }

    /// 是不是“那条订单列表请求”：URL 或响应体里带 order_list / orderList
    private static func isOrderList(url: String, body: String) -> Bool {
        if url.contains("order_list") || url.contains("orderList") { return true }
        if body.contains("orderList") { return true }
        return false
    }

    /// 一条请求的身份：functionId + body。t / uuid 这类每次都变的参数不算，
    /// 这样每次刷新不会把同一查询存成四份，存档里永远是最新的那条 URL。
    private static func requestKey(_ url: String) -> String {
        guard let comps = URLComponents(string: url) else { return url }
        var fid = ""
        var body = ""
        for item in comps.queryItems ?? [] {
            if item.name == "functionId" { fid = item.value ?? "" }
            if item.name == "body" { body = item.value ?? "" }
        }
        if fid.isEmpty && body.isEmpty { return url }
        return fid + "|" + String(body.prefix(400))
    }

    /// 从一次 WebView 抓包结果里挑出订单接口请求并存档（同一查询只留最新一条，最多 4 条）
    static func save(fromPayload payloadJSON: String) {
        guard let arr = entries(payloadJSON) else { return }
        var list = loadAll()
        var changed = false
        for item in arr {
            let resp = item["b"] as? String ?? ""
            let entryURL = item["u"] as? String ?? ""
            guard let req = item["r"] as? [String: Any] else { continue }
            let url = (req["u"] as? String) ?? entryURL
            guard !url.isEmpty, isOrderList(url: url, body: resp) else { continue }
            var headers: [String: String] = [:]
            if let h = req["h"] as? [String: Any] {
                for (k, v) in h { if let s = v as? String { headers[k] = s } }
            }
            let entry = Saved(
                url: url,
                headers: headers,
                savedAt: Date().timeIntervalSince1970,
                method: (req["m"] as? String) ?? "GET",
                body: req["d"] as? String ?? "",
                hit: nil
            )
            let key = requestKey(url)
            if let idx = list.firstIndex(where: { requestKey($0.url) == key }) {
                list[idx] = entry
            } else {
                list.append(entry)
            }
            changed = true
        }
        if changed {
            if list.count > 4 { list = Array(list.suffix(4)) }
            saveAll(list)
        }
    }

    /// 抓包结果里到底有没有可用的订单请求（写进 note，别再静默失败）
    static func diagnose(payloadJSON: String) -> String {
        guard let arr = entries(payloadJSON) else { return "·抓包空" }
        var withReq = 0
        var matched = 0
        var withSign = 0
        var withBody = 0
        for item in arr {
            guard let req = item["r"] as? [String: Any] else { continue }
            withReq += 1
            let url = (req["u"] as? String) ?? (item["u"] as? String ?? "")
            let resp = item["b"] as? String ?? ""
            guard isOrderList(url: url, body: resp) else { continue }
            matched += 1
            if url.contains("sign=") { withSign += 1 }
            if let d = req["d"] as? String, !d.isEmpty { withBody += 1 }
        }
        return "·抓\(arr.count)条/带请求\(withReq)/命中\(matched)/含sign\(withSign)/有body\(withBody)"
    }

    // MARK: - 重放前处理

    /// 把 `t=` 换成当前毫秒时间戳（京东很多接口只把 t 当防缓存，改了也认）
    static func refreshT(_ url: String) -> String {
        let now = String(Int(Date().timeIntervalSince1970 * 1000))
        // 没有 t 就原样返回：乱加参数反而可能让 sign 对不上
        return url.replacingOccurrences(
            of: #"(?<=[?&])t=\d+"#,
            with: "t=" + now,
            options: .regularExpression
        )
    }

    /// fetch 里不能手动设的头（设了会被浏览器丢掉甚至整条失败），交给页面自己补
    private static let forbiddenHeaders: Set<String> = [
        "cookie", "cookie2", "host", "user-agent", "referer", "origin",
        "content-length", "connection", "accept-encoding", "te", "trailer",
        "upgrade", "via", "expect"
    ]

    static func safeHeaders(_ headers: [String: String], body: String) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in headers {
            let lower = k.lowercased()
            if forbiddenHeaders.contains(lower) { continue }
            if lower.hasPrefix("proxy-") || lower.hasPrefix("sec-") { continue }
            if v.isEmpty { continue }
            // 没有请求体却带 Content-Type 反而不合规
            if body.isEmpty && (lower == "content-type" || lower == "content-length") { continue }
            out[k] = v
        }
        return out
    }

    static func statusText() -> String {
        let list = loadAll()
        guard !list.isEmpty else { return "无存档" }
        let url = list.last?.url ?? ""
        let host = URL(string: url)?.host ?? url
        let paramLen = URLComponents(string: url)?.query?.count ?? 0
        let mins = Int(Date().timeIntervalSince1970 - (list.last?.savedAt ?? 0)) / 60
        let bodyLen = (list.last?.body ?? "").count
        return "存档 \(list.count) 份 · \(host) · 参数 \(paramLen) 字节 · 请求体 \(bodyLen) 字节 · \(mins) 分钟前"
    }

    static func jsonQuotedPublic(_ s: String) -> String { jsonQuoted(s) }

    private static func jsonQuoted(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        return "\"\""
    }
}
