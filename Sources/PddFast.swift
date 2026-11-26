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
        // 刚存进来的这几份是「刚刚验证过有 order_sn」的，把黑名单里同 body 的旧标记摘掉，
        // 否则新存档会被自己 15 分钟前的标记挡住。
        if added > 0 {
            var bad = badMap()
            for s in picked { bad.removeValue(forKey: s.body) }
            UserDefaults.standard.set(bad, forKey: badKey)
        }
        return added
    }

    static func loadAll() -> [Saved] {
        guard let data = try? Data(contentsOf: file()) else { return [] }
        guard let list = try? JSONDecoder().decode([Saved].self, from: data) else { return [] }
        return list
    }

    // MARK: - 无效存档的短期黑名单
    //
    // 实测：存档放久了，重放会变成 60 字节的拦截 JSON 或页面那个「探针」空响应。
    // 每次刷新都把这 6 份挨个试一遍，光白等就是四五秒；更要命的是试完还得开 WebView。
    // 这里给「重放已验证无效」的 body 打个短期标记，15 分钟内不再试它。
    private static let badKey = "pdd_bad_bodies"
    private static let badTTL: Double = 15 * 60

    private static func badMap() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: badKey) as? [String: Double] ?? [:]
    }

    static func isKnownBad(_ body: String) -> Bool {
        guard let t = badMap()[body] else { return false }
        return Date().timeIntervalSince1970 - t < badTTL
    }

    static func markBad(_ body: String) {
        var map = badMap()
        let now = Date().timeIntervalSince1970
        map = map.filter { now - $0.value < badTTL }
        map[body] = now
        UserDefaults.standard.set(map, forKey: badKey)
    }

    static func clearBadMarks() {
        UserDefaults.standard.removeObject(forKey: badKey)
    }

    /// 最新一份存档是多少分钟前存的（没有存档返回 -1）。
    /// 快路只在存档新鲜时可信：签名过期后服务端会回「空/旧」的答案，而它不报错。
    static func newestAgeMinutes() -> Int {
        let list = loadAll()
        guard let newest = list.map({ $0.savedAt }).max() else { return -1 }
        return Int((Date().timeIntervalSince1970 - newest) / 60)
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
        r.timeoutInterval = 8
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
