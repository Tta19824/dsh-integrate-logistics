import Foundation

/// 拼多多「直连」快路：把从 WebView 里抓到的 order_list 请求存下来，
/// 之后直接用 URLSession 重放，不再开 WebView。
/// 注意：页面会先后发好几条 order_list（默认/待发货/待收货），
/// 有的返回空列表，所以这里存「一组」请求，重放时逐个试，谁出单就用谁。
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
        return dir.appendingPathComponent("pdd_requests.json")
    }

    static func responseFile() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("pdd_fast_response.json")
    }

    /// 从抓包结果里挑出所有 order_list 请求，去重后存盘（最多 6 份）
    @discardableResult
    static func save(fromPayload payloadJSON: String) -> Int {
        guard let data = payloadJSON.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }

        var picked: [Saved] = loadAll()
        var seen = Set(picked.map { $0.body })
        var added = 0

        for entry in entries {
            guard let raw = entry["r"] as? [String: Any] else { continue }
            let url = (raw["u"] as? String) ?? ""
            guard url.contains("order_list") else { continue }
            let body = (raw["d"] as? String) ?? ""
            let resp = (entry["b"] as? String) ?? ""
            if resp.contains("harmony_empty_height_and_back_refresh") { continue }
            if !resp.contains("order_sn") { continue }
            guard !seen.contains(body) else { continue }
            var headers: [String: String] = [:]
            if let h = raw["h"] as? [String: Any] {
                for (k, v) in h { headers[k] = String(describing: v) }
            }
            seen.insert(body)
            picked.append(Saved(
                url: url,
                method: (raw["m"] as? String) ?? "POST",
                body: body,
                headers: headers,
                savedAt: Date().timeIntervalSince1970
            ))
            added += 1
        }

        if picked.count > 10 { picked = Array(picked.suffix(10)) }
        if let encoded = try? JSONEncoder().encode(picked) {
            try? encoded.write(to: file(), options: .atomic)
        }
        return added
    }

    static func loadAll() -> [Saved] {
        guard let data = try? Data(contentsOf: file()) else { return [] }
        guard let list = try? JSONDecoder().decode([Saved].self, from: data) else { return [] }
        return list
    }

    /// 给调试区看的一句话
    static func statusText() -> String {
        let list = loadAll()
        guard !list.isEmpty else { return "无存档" }
        let newest = list.map { $0.savedAt }.max() ?? 0
        let minutes = Int((Date().timeIntervalSince1970 - newest) / 60)
        let sizes = list.map { String($0.body.count) }.joined(separator: "/")
        return "有存档 \(list.count) 份 · 体 \(sizes) 字节 · \(minutes) 分钟前"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file())
        try? FileManager.default.removeItem(at: responseFile())
    }

    /// 重放，返回状态码与响应正文
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
            ("User-Agent", UserAgent.iOS),
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
