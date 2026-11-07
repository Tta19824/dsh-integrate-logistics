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
}
