import Foundation

/// 直接按订单号请求拼多多的物流接口，拿快递公司、最新一条轨迹和取件码。
/// 这样刷新一次就能把列表卡片填满，不需要用户点进任何页面。
enum ShippingClient {
    struct Info {
        var carrier = ""
        var pickup = ""
        var logistics = ""
    }

    static func fetch(orderNo: String, cookieHeader: String) async -> Info? {
        guard let uid = userID(from: cookieHeader), !uid.isEmpty else { return nil }
        let encoded = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
        let raw = "https://mobile.pinduoduo.com/proxy/api/order/\(encoded)/shipping?pdduid=\(uid)&query_type=2"
        guard let url = URL(string: raw) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://mobile.pinduoduo.com/order.html", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        var info = Info()
        walk(object, into: &info)
        if info.pickup.isEmpty {
            info.pickup = DetailParser.pickupCode(from: String(data: data, encoding: .utf8) ?? "")
        }
        if info.carrier.isEmpty {
            info.carrier = PinduoduoParser.carrierName(from: String(data: data, encoding: .utf8) ?? "") ?? ""
        }
        if info.carrier.isEmpty && info.pickup.isEmpty && info.logistics.isEmpty { return nil }
        return info
    }

    /// 从 cookie 里取 pdd_user_id，物流接口的 pdduid 就是它。
    private static func userID(from cookieHeader: String) -> String? {
        for part in cookieHeader.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespaces)
            if name == "pdd_user_id" {
                return pieces[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private struct Trace {
        var info = ""
        var time = ""
    }

    private static func walk(_ object: Any, into result: inout Info) {
        if let dict = object as? [String: Any] {
            if result.carrier.isEmpty, let name = dict["shipping_name"] as? String, !name.isEmpty {
                result.carrier = name
            }
            if let text = dict["info"] as? String, !text.isEmpty {
                let time = (dict["time"] as? String) ?? ""
                let line = time.isEmpty ? text : "\(text)"
                if result.logistics.isEmpty { result.logistics = line }
                if result.pickup.isEmpty {
                    let code = DetailParser.pickupCode(from: text)
                    if !code.isEmpty { result.pickup = code }
                }
            }
            for value in dict.values { walk(value, into: &result) }
        } else if let array = object as? [Any] {
            for value in array { walk(value, into: &result) }
        }
    }

    /// 拉一份原始物流 JSON，顺带把轨迹解析好。
    struct TrackResult {
        var events: [ShipEvent]
        var data: Data
        var tracking: String
        var address: String
    }

    static func track(orderNo: String, cookieHeader: String) async -> TrackResult? {
        guard let uid = userID(from: cookieHeader), !uid.isEmpty else { return nil }
        let encoded = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
        let raw = "https://mobile.pinduoduo.com/proxy/api/order/\(encoded)/shipping?pdduid=\(uid)&query_type=2"
        guard let url = URL(string: raw) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://mobile.pinduoduo.com/order.html", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return TrackResult(
            events: ShipTracking.events(from: data),
            data: data,
            tracking: ShipTracking.trackingNumber(from: data),
            address: ShipTracking.destination(from: data)
        )
    }
}


/// 淘宝的物流详情页是服务端渲染的：一次 GET 回来的 HTML 里就带着完整轨迹节点，
/// 不需要开 WebView、不需要执行 JS。抓不到（比如要求登录）再回退到 WebView。
/// 淘宝「已买到的宝贝」PC 页：跟物流页一样是按登录态服务端渲染，
/// 带 cookie 直连就能拿到带订单的 HTML，不用开 WebView。
enum TaobaoListHTML {
    /// 上一次直连拿到的元信息（HTTP 码、内容类型、最终地址、字节数），用来诊断
    static var lastMeta = ""

    /// 淘宝 PC 页在部分情况下不是 UTF-8（登录页/风控页常见 GBK），先按 UTF-8 解，乱码多了就换 GB18030
    static func decodeHTML(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            let bad = utf8.filter { $0 == "\u{FFFD}" }.count
            if bad <= 3 { return utf8 }
        }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let gbk = String(data: data, encoding: String.Encoding(rawValue: gb)) { return gbk }
        return String(decoding: data, as: UTF8.self)
    }

    static func rawHTML(cookieHeader: String) async -> String? {
        let raw = "https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm"
        guard let url = URL(string: raw) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://buyertrade.taobao.com/", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let html = decodeHTML(data)
        let ctype = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
        let finalHost = http.url?.host ?? "?"
        lastMeta = "\(http.statusCode) · \(ctype) · \(finalHost) · \(data.count) 字节"
        return html.count > 5000 ? html : nil
    }
}

enum TaobaoLogistics {
    /// 直接带 cookie 请求物流页，原样返回 HTML（不做内容判断，供诊断用）
    static func rawHTML(orderNo: String, cookieHeader: String) async -> String? {
        let encoded = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
        let raw = "https://market.m.taobao.com/app/dinamic/pc-trade-logistics/home.html?orderId=\(encoded)&entrance=pc"
        guard let url = URL(string: raw) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func traceHTML(orderNo: String, cookieHeader: String) async -> String? {
        let encoded = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
        let raw = "https://market.m.taobao.com/app/dinamic/pc-trade-logistics/home.html?orderId=\(encoded)&entrance=pc"
        guard let url = URL(string: raw) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        if TaobaoJdParser.parseTaobaoTraceHTML(html).count >= 2 { return html }
        return nil
    }
}
