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
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
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
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.jd.com/", forHTTPHeaderField: "Referer")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (status, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }

    static func requestDetail(_ req: Req) -> String {
        var dict: [String: Any] = ["url": req.url, "method": req.method, "headers": req.headers]
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
