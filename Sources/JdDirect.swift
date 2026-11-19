import Foundation

/// 京东「直连」实验：把 WebView 里抓到的订单请求原样重放一次，
/// 看服务端认不认（`x-api-eid-token` 这类设备令牌可能会拒绝）。
enum JdDirect {
    struct Req {
        let url: String
        let method: String
        let headers: [String: String]
        let body: String?
    }

    /// 从抓包结果里找出「返回 orderList 的那条请求」
    static func findRequest(in payloadJSON: String) -> Req? {
        guard let data = payloadJSON.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for entry in entries {
            guard let body = entry["b"] as? String, body.contains("orderList"),
                  let raw = entry["r"] as? [String: Any] else { continue }
            let url = (raw["u"] as? String) ?? (entry["u"] as? String) ?? ""
            guard !url.isEmpty else { continue }
            var headers: [String: String] = [:]
            if let h = raw["h"] as? [String: Any] {
                for (k, v) in h { headers[k] = String(describing: v) }
            }
            var reqBody: String? = raw["d"] as? String
            if let b = reqBody, b.isEmpty { reqBody = nil }
            return Req(url: url, method: (raw["m"] as? String) ?? "POST", headers: headers, body: reqBody)
        }
        return nil
    }

    static func requestFile() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jd_request.json")
    }

    /// 重放并返回一行结果，直接显示在「最近一次结果」里
    static func probe(payloadJSON: String, cookie: String) async -> String {
        guard let req = findRequest(in: payloadJSON) else {
            return "直连探测：没找到京东订单请求"
        }
        try? requestDetail(req).data(using: .utf8)?.write(to: requestFile(), options: .atomic)

        guard let url = URL(string: req.url) else { return "直连探测：URL 非法" }
        var r = URLRequest(url: url)
        r.httpMethod = req.method
        r.timeoutInterval = 15
        let skip: Set<String> = ["cookie", "content-length", "host", "connection", "accept-encoding"]
        for (k, v) in req.headers where !skip.contains(k.lowercased()) {
            r.setValue(v, forHTTPHeaderField: k)
        }
        // 浏览器自己补的头，JS 抓不到，重放时手动补齐
        let ua = UserAgent.iOS
        let defaults: [(String, String)] = [
            ("User-Agent", ua),
            ("Accept", "application/json, text/plain, */*"),
            ("Accept-Language", "zh-CN,zh;q=0.9"),
            ("Referer", "https://my.m.jd.com/"),
            ("Origin", "https://my.m.jd.com")
        ]
        for (key, value) in defaults where r.value(forHTTPHeaderField: key) == nil {
            r.setValue(value, forHTTPHeaderField: key)
        }
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let body = req.body, req.method.uppercased() != "GET" {
            r.httpBody = body.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            let orders = occurrences(of: "\"orderId\"", in: text)
            let message = jsonMessage(text)
            var line = "直连探测：HTTP \(code) · \(data.count) 字节 · 订单 \(orders) 条"
            if !message.isEmpty { line += " · \(message)" }
            line += " · 发出 \(req.method) \(shortURL(req.url)) · 体 \(req.body?.count ?? 0) 字节"
            line += " · 回应「\(preview(text))」"
            return line
        } catch {
            return "直连探测：失败 \(error.localizedDescription)"
        }
    }

    /// 直取 PC 订单页 HTML：带钥匙串 cookie，走 URLSession，不经 WebView。
    /// 实测日志：页面是服务端渲染（登录态在 HTML 里），所以这条路有可能又快又准。
    static func fetchOrderListHTML(cookie: String) async -> (status: Int, html: String) {
        guard let url = URL(string: "https://order.jd.com/center/list.action") else { return (0, "") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(UserAgent.macOS, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.jd.com/", forHTTPHeaderField: "Referer")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (status, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }

    // MARK: - 翻页（订单列表一页 10 条，第 11 单起必须自己去要）

    /// 抓包记录是 `{"u":…,"r":…,"b":…}`，这里把请求 URL 取出来。
    static func url(ofEntry entry: String) -> String? {
        guard let d = entry.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let u = obj["u"] as? String, !u.isEmpty else { return nil }
        return u
    }

    /// 把 `api.m.jd.com` 请求里 `body` 参数中的 `page` 改成指定页。
    /// 京东的 `order_list_m` 分页就在 body 的 JSON 里（`page`/`pageNo`），改了再 GET 一次即可。
    static func urlReplacingPage(_ url: String, page: Int) -> String? {
        guard let r = url.range(of: "&body=") ?? url.range(of: "?body=") else { return nil }
        let head = String(url[..<r.upperBound])
        let rest = String(url[r.upperBound...])
        let amp = rest.firstIndex(of: "&")
        let rawValue = amp.map { String(rest[..<$0]) } ?? rest
        let tail = amp.map { String(rest[$0...]) } ?? ""
        guard let decoded = rawValue.removingPercentEncoding,
              let data = decoded.data(using: .utf8),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        dict["page"] = page
        dict["pageNo"] = page
        guard let newData = try? JSONSerialization.data(withJSONObject: dict),
              let newBody = String(data: newData, encoding: .utf8),
              let encoded = newBody.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return head + encoded + tail
    }

    /// 把接口返回的响应体包成一条「抓包记录」，好让 `parseJdOrderList` 直接吃。
    static func entryWrapping(body: String) -> String {
        let dict: [String: Any] = ["b": body]
        guard let d = try? JSONSerialization.data(withJSONObject: [dict]),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    static func requestDetail(_ req: Req) -> String {        var dict: [String: Any] = ["url": req.url, "method": req.method, "headers": req.headers]
        if let body = req.body { dict["body"] = body }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func shortURL(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return raw }
        var path = url.path
        if path.count > 40 { path = String(path.suffix(40)) }
        return (url.host ?? "?") + path
    }

    private static func preview(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\r", with: " ")
        return String(one.prefix(110))
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var idx = haystack.startIndex
        while let found = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            count += 1
            idx = found.upperBound
            if count > 500 { break }
        }
        return count
    }

    private static func jsonMessage(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        var parts: [String] = []
        if let code = root["code"] { parts.append("code=\(code)") }
        if let message = root["message"] as? String, !message.isEmpty { parts.append(message) }
        return parts.joined(separator: " ")
    }
}
