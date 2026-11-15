import Foundation
import CryptoKit

/// 淘宝「已买到的宝贝」直连：页面是 React 空壳，订单来自 mtop 的 queryboughtlistV2。
/// mtop 的 sign = md5(token + "&" + t + "&" + appKey + "&" + data)，token 取自 _m_h5_tk cookie。
enum TbFast {

    struct Result {
        var orders: [Order] = []
        var tracking = ""
        var carrier = ""
        var note = ""
    }

    static let appKey = "12574478"
    static let dataJSON = "{\"tabCode\":\"all\",\"page\":1,\"OrderType\":\"OrderList\",\"appName\":\"tborder\",\"appVersion\":\"3.0\",\"condition\":\"{\\\"directRouteToTm2Scene\\\":\\\"1\\\"}\",\"__needlessClearProtocol__\":true}"

    /// 从 cookie 头里取 _m_h5_tk 的 token（形如 "abc123_1699999999999" 取前半段）
    static func token(from cookie: String) -> String? {
        for part in cookie.components(separatedBy: ";") {
            let kv = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard kv.hasPrefix("_m_h5_tk=") else { continue }
            let value = String(kv.dropFirst("_m_h5_tk=".count))
            guard let underscore = value.firstIndex(of: "_") else { continue }
            let t = String(value[value.startIndex..<underscore])
            return t.isEmpty ? nil : t
        }
        return nil
    }

    static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func request(cookie: String, page: Int = 1) -> URLRequest? {
        guard let tk = token(from: cookie) else { return nil }
        let t = Int(Date().timeIntervalSince1970 * 1000)
        let data = dataJSON.replacingOccurrences(of: "\"page\":1", with: "\"page\":\(page)")
        let sign = md5Hex("\(tk)&\(t)&\(appKey)&\(data)")
        var comps = URLComponents(string: "https://h5api.m.taobao.com/h5/mtop.taobao.order.queryboughtlistv2/1.0/")!
        comps.queryItems = [
            URLQueryItem(name: "jsv", value: "2.7.2"),
            URLQueryItem(name: "appKey", value: appKey),
            URLQueryItem(name: "t", value: String(t)),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "v", value: "1.0"),
            URLQueryItem(name: "ecode", value: "1"),
            URLQueryItem(name: "timeout", value: "8000"),
            URLQueryItem(name: "dataType", value: "json"),
            URLQueryItem(name: "valueType", value: "original"),
            URLQueryItem(name: "ttid", value: "1@tbwang_unknown_1.0.0#pc"),
            URLQueryItem(name: "needLogin", value: "true"),
            URLQueryItem(name: "type", value: "originaljson"),
            URLQueryItem(name: "isHttps", value: "1"),
            URLQueryItem(name: "needRetry", value: "true"),
            URLQueryItem(name: "api", value: "mtop.taobao.order.queryboughtlistV2"),
            URLQueryItem(name: "__customTag__", value: "boughtList_all_OrderList"),
            URLQueryItem(name: "preventFallback", value: "true")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm", forHTTPHeaderField: "Referer")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = data.addingPercentEncoding(withAllowedCharacters: allowed) ?? data
        req.httpBody = Data("data=\(encoded)".utf8)
        return req
    }

    static func fetch(cookie: String) async -> Result {
        guard !cookie.isEmpty else { return Result(note: "淘宝直连：没有 cookie") }
        guard token(from: cookie) != nil else { return Result(note: "淘宝直连：cookie 里没有 _m_h5_tk") }
        guard let req = request(cookie: cookie) else { return Result(note: "淘宝直连：请求构造失败") }
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            guard status == 200 else {
                return Result(note: "淘宝直连：HTTP \(status) · \(body.count) 字节")
            }
            // 解析器要求 entry["b"] 是「响应体字符串」，所以这里用 JSONSerialization 做转义，不能直接嵌对象
            let wrapped = wrap(body)
            let orders = TaobaoJdParser.parseTaobaoBoughtList(payloadJSON: wrapped)
            if orders.isEmpty {
                let head = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(70).replacingOccurrences(of: "\n", with: " ")
                return Result(note: "淘宝直连：\(body.count) 字节 · 0 条 · 开头「\(head)」")
            }
            var result = Result()
            result.orders = orders
            result.note = "淘宝直连 \(orders.count) 条订单"
            try? body.data(using: .utf8)?.write(to: OrderClient.payloadFile(for: .tb), options: .atomic)
            return result
        } catch {
            return Result(note: "淘宝直连失败：\(error.localizedDescription)")
        }
    }

    /// 把响应体包成解析器认识的格式：[{ "u": "...", "b": "<响应体字符串>" }]
    static func wrap(_ body: String) -> String {
        let entry: [String: Any] = ["u": "mtop.order.queryboughtlistv2", "b": body]
        guard let data = try? JSONSerialization.data(withJSONObject: [entry]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
