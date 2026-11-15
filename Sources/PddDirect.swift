import Foundation

/// 拼多多「直连」实验：把 WebView 里抓到的 order_list 请求原样重放，
/// 看服务端认不认（拼多多这个接口看起来没有签名参数）。
enum PddDirect {
    struct Req {
        let url: String
        let method: String
        let headers: [String: String]
        let body: String?
    }

    static func findRequest(in payloadJSON: String) -> Req? {
        guard let data = payloadJSON.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for entry in entries {
            guard let body = entry["b"] as? String, body.contains("order_list"),
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

    /// 重放并返回一行结果
    static func probe(payloadJSON: String, cookie: String) async -> String {
        guard let req = findRequest(in: payloadJSON) else {
            return "直连探测：没找到拼多多订单请求"
        }
        guard let url = URL(string: req.url) else { return "直连探测：URL 非法" }
        var r = URLRequest(url: url)
        r.httpMethod = req.method
        r.timeoutInterval = 15
        let skip: Set<String> = ["cookie", "content-length", "host", "connection", "accept-encoding"]
        for (k, v) in req.headers where !skip.contains(k.lowercased()) {
            r.setValue(v, forHTTPHeaderField: k)
        }
        let defaults: [(String, String)] = [
            ("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"),
            ("Accept", "application/json, text/plain, */*"),
            ("Accept-Language", "zh-CN,zh;q=0.9"),
            ("Referer", "https://mobile.pinduoduo.com/order.html"),
            ("Origin", "https://mobile.pinduoduo.com")
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
            let orders = occurrences(of: "order_sn", in: text)
            var line = "拼多多直连：HTTP \(code) · \(data.count) 字节 · order_sn ×\(orders) · \(req.method) \(hostPath(req.url)) · 体 \(req.body?.count ?? 0) 字节"
            if orders == 0 {
                line += " · 开头「\(String(text.prefix(80)))」"
            }
            return line
        } catch {
            return "拼多多直连：失败 \(error.localizedDescription)"
        }
    }

    private static func hostPath(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return raw }
        var path = url.path
        if path.count > 34 { path = String(path.suffix(34)) }
        return (url.host ?? "?") + path
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
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
}
