import Foundation

/// 京东：把手机版订单列表页发出的那条已签名请求存下来，下次先直连重放。
/// 思路照搬拼多多 PddFast：签名在 URL 里，原样重放即可（过期就回退 WebView）。
enum JdFast {
    struct Saved: Codable {
        var url: String
        var headers: [String: String]
        var savedAt: TimeInterval
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

    /// 从一次 WebView 抓包结果里挑出订单接口请求并存档（按 URL 去重，最多 4 条）
    static func save(fromPayload payloadJSON: String) {
        guard let data = payloadJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var list = loadAll()
        for item in arr {
            guard let url = item["u"] as? String, url.contains("order_list") else { continue }
            guard let req = item["r"] as? [String: Any] else { continue }
            var headers: [String: String] = [:]
            if let h = req["h"] as? [String: Any] {
                for (k, v) in h { if let s = v as? String { headers[k] = s } }
            }
            if list.contains(where: { $0.url == url }) { continue }
            list.append(Saved(url: url, headers: headers, savedAt: Date().timeIntervalSince1970))
        }
        if list.count > 4 { list = Array(list.suffix(4)) }
        saveAll(list)
    }

    /// 最近一条存档的 URL（页内直取用）
    static func lastURL() -> String? { loadAll().last?.url }

    static func statusText() -> String {
        let list = loadAll()
        guard !list.isEmpty else { return "无存档" }
        let url = list.last?.url ?? ""
        let host = URL(string: url)?.host ?? url
        let bodyLen = URLComponents(string: url)?.query?.count ?? 0
        let mins = Int(Date().timeIntervalSince1970 - (list.last?.savedAt ?? 0)) / 60
        return "存档 \(list.count) 份 · \(host) · 参数 \(bodyLen) 字节 · \(mins) 分钟前"
    }

    /// 逐份重放，返回 (payloadJSON, 诊断)
    static func replay(cookie: String) async -> (wrapped: String?, note: String) {
        let list = loadAll()
        guard !list.isEmpty else { return (nil, "；快路：无存档") }
        var detail: [String] = []
        for (idx, saved) in list.enumerated() {
            guard let url = URL(string: saved.url) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            var ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
            for (k, v) in saved.headers {
                let lower = k.lowercased()
                if v.contains("$") { continue }
                if lower == "cookie" || lower == "content-length" || lower == "host" { continue }
                if lower == "user-agent" { ua = v; continue }
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue("https://my.m.jd.com/", forHTTPHeaderField: "Referer")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
                detail.append("网络失败")
                continue
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            if code != 200 { detail.append("HTTP" + String(code)); continue }
            if !body.contains("orderList") { detail.append(String(data.count) + "B无orderList"); continue }
            let wrapped = "[{" + jsonQuoted("u") + ":" + jsonQuoted(saved.url) + "," + jsonQuoted("b") + ":" + jsonQuoted(body) + "}]"
            return (wrapped, "；快路：第 " + String(idx + 1) + "/" + String(list.count) + " 份重放成功")
        }
        return (nil, "；快路：" + detail.joined(separator: "/"))
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
