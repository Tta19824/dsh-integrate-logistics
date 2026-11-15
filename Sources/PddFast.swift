import Foundation

/// 拼多多「直连」快路：把第一次从 WebView 里抓到的 order_list 请求存下来，
/// 之后直接用 URLSession 重放，不再开 WebView。
/// 实测（0.21.3）：HTTP 200 · 59,835 字节 · order_sn ×56，服务端认这份请求。
enum PddFast {
    struct Saved: Codable {
        let url: String
        let method: String
        let body: String
        let headers: [String: String]
        let savedAt: Double
    }

    static func file() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("pdd_request.json")
    }

    /// 从抓包结果里挑出 order_list 那条请求并存盘
    @discardableResult
    static func save(fromPayload payloadJSON: String) -> Bool {
        guard let data = payloadJSON.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        // 页面上会先后发好几次 order_list（默认全部 / 待发货 / 待收货），
        // 用户关心的是最后那个 tab 的结果，所以留最后一条。
        var picked: Saved?
        for entry in entries {
            guard let raw = entry["r"] as? [String: Any] else { continue }
            let url = (raw["u"] as? String) ?? ""
            guard url.contains("order_list") else { continue }
            var headers: [String: String] = [:]
            if let h = raw["h"] as? [String: Any] {
                for (k, v) in h { headers[k] = String(describing: v) }
            }
            picked = Saved(
                url: url,
                method: (raw["m"] as? String) ?? "POST",
                body: (raw["d"] as? String) ?? "",
                headers: headers,
                savedAt: Date().timeIntervalSince1970
            )
        }
        guard let saved = picked, let encoded = try? JSONEncoder().encode(saved) else { return false }
        try? encoded.write(to: file(), options: .atomic)
        return true
    }

    static func load() -> Saved? {
        guard let data = try? Data(contentsOf: file()) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func responseFile() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("pdd_fast_response.json")
    }

    /// 给调试区看的一句话
    static func statusText() -> String {
        guard let saved = load() else { return "无存档" }
        let minutes = Int((Date().timeIntervalSince1970 - saved.savedAt) / 60)
        let host = URL(string: saved.url)?.host ?? "?"
        return "有存档 · \(host) · 体 \(saved.body.count) 字节 · \(minutes) 分钟前"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file())
    }

    /// 重放，返回响应正文（失败返回 nil）
    static func replay(_ saved: Saved, cookie: String) async -> (status: Int, text: String)? {
        guard let url = URL(string: saved.url) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = saved.method
        r.timeoutInterval = 20
        let skip: Set<String> = ["cookie", "content-length", "host", "connection", "accept-encoding"]
        for (k, v) in saved.headers where !skip.contains(k.lowercased()) {
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
        if !saved.body.isEmpty, saved.method.uppercased() != "GET" {
            r.httpBody = saved.body.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            return (status, text)
        } catch {
            return nil
        }
    }

    /// 把直连响应包成抓包格式，交给现成的解析器
    static func payloadJSON(url: String, body: String) -> String {
        let item: [String: Any] = ["u": url, "b": body]
        guard let data = try? JSONSerialization.data(withJSONObject: [item], options: []),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
