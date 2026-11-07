import Foundation

enum HTMLTools {
    /// 去掉标签、脚本、样式，压缩空白，留下可读文本。
    static func strip(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?is)<script.*?</script>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<style.*?</style>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)</(div|li|p|tr|h\\d)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "[ \\t\\u{00a0}]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
        return s
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        if m.numberOfRanges > 1 {
            let r = m.range(at: 1)
            if r.location != NSNotFound { return ns.substring(with: r) }
        }
        return ns.substring(with: m.range)
    }

    static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map { m in
            m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range)
        }
    }
}

/// 稳定的字符串哈希（Swift 的 hashValue 每次启动都变，不能拿来做订单主键）
func stableHash(_ text: String) -> String {
    var hash: UInt64 = 5381
    for byte in text.utf8 {
        hash = (hash &* 33) &+ UInt64(byte)
    }
    return String(hash, radix: 16)
}

/// 拼多多订单页是前端渲染的空壳，HTML 里没有订单数据。
/// 所以解析分两路：优先吃 WebView 抓到的接口 JSON，退而求其次吃渲染后的纯文本。
enum PinduoduoParser {
    static let statusWords = [
        "待发货", "待收货", "待付款", "已完成", "已取消", "已签收",
        "交易成功", "交易关闭", "退款中", "待成团", "拼单成功", "待评价",
        "待取件", "运输中", "派送中", "已发货"
    ]

    // MARK: 入口

    static func parse(text: String, payloadJSON: String, now: Date = Date()) -> [Order] {
        let fromJSON = parsePayload(payloadJSON, now: now)
        if !fromJSON.isEmpty { return fromJSON }
        return parseText(text, now: now)
    }

    static func parse(html: String, now: Date = Date()) -> [Order] {
        parseText(HTMLTools.strip(html), now: now)
    }

    // MARK: 接口 JSON

    static func parsePayload(_ jsonText: String, now: Date = Date()) -> [Order] {
        guard let data = jsonText.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var dicts: [[String: Any]] = []
        for entry in entries {
            guard let body = entry["b"] as? String,
                  let bodyData = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bodyData)
            else { continue }
            collectOrderDicts(obj, into: &dicts)
        }

        var orders: [Order] = []
        var seen = Set<String>()
        for dict in dicts {
            guard let order = makeOrder(from: dict, now: now) else { continue }
            guard !seen.contains(order.id) else { continue }
            seen.insert(order.id)
            orders.append(order)
        }
        return orders
    }

    private static func collectOrderDicts(_ obj: Any, into out: inout [[String: Any]]) {
        if let dict = obj as? [String: Any] {
            if looksLikeOrder(dict) { out.append(dict) }
            for (_, value) in dict { collectOrderDicts(value, into: &out) }
        } else if let arr = obj as? [Any] {
            for value in arr { collectOrderDicts(value, into: &out) }
        }
    }

    private static func looksLikeOrder(_ dict: [String: Any]) -> Bool {
        let keys = Set(dict.keys)
        let hasNo = !keys.isDisjoint(with: ["order_sn", "orderSn", "order_sn_str", "orderSnStr", "order_no", "orderNo"])
        let hasBody = !keys.isDisjoint(with: [
            "goods", "goods_list", "goodsList", "order_goods", "orderGoods",
            "order_goods_list", "orderGoodsList", "items", "goods_info",
            "order_status", "orderStatus", "order_status_desc", "orderStatusDesc", "status_desc",
            "order_status_prompt", "order_amount", "orderAmount", "pay_amount", "payAmount"
        ])
        return hasNo && hasBody
    }

    private static func makeOrder(from dict: [String: Any], now: Date) -> Order? {
        let orderNo = firstString(dict, [
            "order_sn", "orderSn", "order_sn_str", "orderSnStr", "order_no", "orderNo"
        ]) ?? ""
        guard orderNo.count >= 8 else { return nil }

        let prompt = firstString(dict, [
            "order_status_prompt", "orderStatusPrompt", "order_status_desc", "orderStatusDesc",
            "status_desc", "statusDesc", "order_status_str", "status_str", "status_text", "statusText"
        ]) ?? ""
        let code = firstInt(dict, ["status", "order_status", "orderStatus"]) ?? -1
        let statusRaw = prompt.isEmpty ? (code >= 0 ? "状态码 \(code)" : "未识别") : prompt

        var amount = firstString(dict, [
            "display_amount", "order_amount", "orderAmount", "pay_amount", "payAmount",
            "total_amount", "totalAmount", "amount"
        ]) ?? ""
        if let cents = dict["pay_amount_cent"] as? Int, amount.isEmpty {
            amount = String(cents)
        }
        amount = normalizeAmount(amount)

        var title = ""
        var imageURL = ""
        var goodsID = ""
        var shop = ""
        if let mall = dict["mall"] as? [String: Any] {
            shop = firstString(mall, ["mall_name", "mallName", "mall_title", "mallTitle", "shop_name", "shopName", "store_name", "storeName"]) ?? ""
        }
        if shop.isEmpty {
            shop = firstString(dict, ["mall_name", "mallName", "store_name", "storeName", "shop_name", "shopName"]) ?? ""
        }
        for key in ["order_goods", "orderGoods", "goods", "goods_list", "goodsList", "order_goods_list", "orderGoodsList", "items", "goods_info"] {
            guard let arr = dict[key] as? [[String: Any]], let first = arr.first else { continue }
            title = firstString(first, ["goods_name", "goodsName", "goods_title", "goodsTitle", "title", "name"]) ?? ""
            imageURL = firstString(first, ["thumb_url", "thumbUrl", "hd_thumb_url", "hdThumbUrl", "image_url", "imageUrl", "goods_image", "goodsImage"]) ?? ""
            goodsID = firstString(first, ["goods_id", "goodsId"]) ?? ""
            if shop.isEmpty {
                shop = firstString(first, ["mall_name", "mallName", "store_name"]) ?? ""
            }
            if amount.isEmpty {
                amount = firstString(first, ["goods_price", "goodsPrice", "price"]) ?? ""
            }
            if !title.isEmpty { break }
        }

        let time = firstString(dict, [
            "create_time", "createTime", "order_time", "orderTime", "order_create_time", "orderCreateTime"
        ]) ?? ""

        return Order(
            id: Order.makeID(platform: .pdd, orderNo: orderNo),
            platform: .pdd,
            orderNo: orderNo,
            title: title,
            shopName: shop,
            amount: amount,
            status: pddStatus(code: code, prompt: prompt),
            statusRaw: statusRaw.isEmpty ? "未识别" : statusRaw,
            orderTime: normalizeTime(time),
            logistics: "",
            pickupCode: "",
            imageURL: imageURL,
            goodsID: goodsID,
            updatedAt: now
        )
    }

    /// 平台接口里的金额基本是「分」，界面上要显示成两位小数的元。
    /// 已经是小数的原样保留；纯整数的除以 100。
    private static func normalizeAmount(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["¥", "￥"] where s.hasPrefix(prefix) {
            s.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        if s.contains(".") {
            if let v = Double(s), v.rounded() != v || s.count <= 8 {
                return String(format: "%.2f", v)
            }
            return s
        }
        guard s.allSatisfy({ $0.isNumber }), let cents = Double(s) else { return s }
        return String(format: "%.2f", cents / 100.0)
    }

    private static func normalizeTime(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if raw.count >= 10, raw.first.map({ $0.isNumber }) == true, !raw.contains("-") {
            if let seconds = Double(raw) {
                let date = Date(timeIntervalSince1970: seconds > 1_000_000_000_000 ? seconds / 1000 : seconds)
                return date.formatted(date: .numeric, time: .shortened)
            }
        }
        return raw
    }

    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let s = dict[key] as? String, !s.isEmpty, s != "0" { return s }
            if let n = dict[key] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    private static func firstInt(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let n = dict[key] as? Int { return n }
            if let n = dict[key] as? NSNumber { return n.intValue }
            if let s = dict[key] as? String, let v = Int(s) { return v }
        }
        return nil
    }

    /// 拼多多的状态是数字码，但每单还带一句 prompt（充值到账 / 交易成功 / 交易已取消…），
    /// prompt 更准，先用它，认不出再退回数字码。
    static func pddStatus(code: Int, prompt: String) -> OrderStatus {
        if prompt.contains("取消") || prompt.contains("关闭") { return .cancelled }
        if prompt.contains("退款") || prompt.contains("售后") || prompt.contains("退货") { return .refunding }
        if prompt.contains("待收货") || prompt.contains("运输") || prompt.contains("派送") || prompt.contains("待取件") { return .shipped }
        if prompt.contains("待发货") || prompt.contains("打包") || prompt.contains("待成团") { return .paid }
        if prompt.contains("待付款") || prompt.contains("待支付") { return .unpaid }
        if prompt.contains("成功") || prompt.contains("到账") || prompt.contains("完成") || prompt.contains("已签收") { return .completed }
        switch code {
        case 0: return .unpaid
        case 1, 2, 3: return .shipped
        case 4, 5: return .completed
        case 6: return .refunding
        case 7: return .cancelled
        default: return .unknown
        }
    }

    // MARK: 渲染后纯文本

    static func parseText(_ text: String, now: Date = Date()) -> [Order] {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var orders: [Order] = []
        var seen = Set<String>()

        for (index, line) in lines.enumerated() {
            guard line.count <= 14, let status = statusWords.first(where: { line.contains($0) }) else { continue }
            let lower = max(0, index - 5)
            let window = Array(lines[lower...index])
            guard let title = guessTitle(from: window) else { continue }
            let amount = window.compactMap { HTMLTools.firstMatch("(?:¥|￥)\\s*([0-9]+(?:\\.[0-9]{1,2})?)", in: $0) }.first ?? ""
            let key = "\(title)|\(amount)|\(status)"
            let orderNo = "T" + stableHash(key).uppercased()
            let id = Order.makeID(platform: .pdd, orderNo: orderNo)
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            orders.append(Order(
                id: id,
                platform: .pdd,
                orderNo: orderNo,
                title: title,
                shopName: "",
                amount: amount,
                status: OrderStatus.parse(status),
                statusRaw: status,
                orderTime: "",
                logistics: "",
                pickupCode: "",
                updatedAt: now
            ))
        }
        return orders
    }

    private static func guessTitle(from window: [String]) -> String? {
        let banned = ["订单号", "订单编号", "实付", "合计", "运费", "优惠", "查看物流",
                      "确认收货", "再次购买", "申请售后", "评价", "删除", "更多", "全部"]
        for line in window.reversed() {
            guard line.count >= 6 else { continue }
            if banned.contains(where: { line.contains($0) }) { continue }
            if line.allSatisfy({ $0.isNumber || "-:：¥￥. ".contains($0) }) { continue }
            if statusWords.contains(where: { line.contains($0) }) && line.count < 8 { continue }
            return String(line.prefix(60))
        }
        return nil
    }
}

struct TraceEntry: Identifiable {
    let id: Int
    let time: String
    let text: String
}

enum DetailParser {
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 真实店铺名。百亿补贴/品牌馆订单的 mall_name 是品牌馆名字（如「百亿补贴·宝格丽」），
    /// 真正的商家只在订单详情页里出现，所以这里从详情页的接口数据和正文里捞。
    static func shopName(payloadJSON: String, text: String) -> String {
        if let data = payloadJSON.data(using: .utf8),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in entries {
                guard let body = entry["b"] as? String,
                      let bodyData = body.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: bodyData) else { continue }
                if let hit = findShop(in: obj) { return hit }
            }
        }
        return firstMatch("([\\u4e00-\\u9fa5A-Za-z0-9（）()·]{2,18}(?:专营店|专卖店|旗舰店|官方店|品牌店))", in: text) ?? ""
    }

    private static func findShop(in obj: Any) -> String? {
        if let dict = obj as? [String: Any] {
            for key in ["mall_name", "mallName", "shop_name", "shopName", "store_name", "storeName", "mall_title", "mallTitle"] {
                if let value = dict[key] as? String, looksLikeShop(value) { return value }
            }
            for value in dict.values {
                if let hit = findShop(in: value) { return hit }
            }
        } else if let arr = obj as? [Any] {
            for value in arr {
                if let hit = findShop(in: value) { return hit }
            }
        }
        return nil
    }

    private static func looksLikeShop(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 4, s.count <= 30 else { return false }
        if s.hasPrefix("百亿补贴") || s.hasPrefix("品牌馆") { return false }
        return ["专营店", "专卖店", "旗舰店", "官方店", "企业店"].contains { s.contains($0) }
    }

    static func isLikelyShop(_ raw: String) -> Bool { looksLikeShop(raw) }

    /// 取件码，例如「取件码：8-2-1234」
    static func pickupCode(from text: String) -> String {
        firstMatch("(?:取件码|提货码|取货码|取件号)[^0-9A-Za-z\\-]{0,8}([0-9A-Za-z\\-]{3,14})", in: text)
            ?? firstMatch("([0-9]{1,2}-[0-9]{1,2}-[0-9]{3,8})", in: text)
            ?? ""
    }

    /// 当前物流状态词
    static func statusWord(from text: String) -> String {
        let words = ["已签收", "派送中", "派件中", "待取件", "运输中", "已发货", "已揽收", "待发货", "打包中", "待收货"]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.count > 20 { continue }
            if words.contains(where: { line == $0 || line.hasPrefix($0 + " ") }) { return line }
        }
        return ""
    }

    /// 快递单号
    static func trackingNumber(from text: String) -> String {
        if let hit = firstMatch("(?:运单号|快递单号|快递编号)[：:\\s]*([0-9]{8,24})", in: text) { return hit }
        if let hit = firstMatch("([0-9]{12,24})", in: text) { return hit }
        return ""
    }

    /// 物流轨迹：形如「2026-11-07 11:05:16」后面跟一行说明
    static func trace(from text: String) -> [TraceEntry] {
        guard let re = try? NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}(:\\d{2})?") else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [TraceEntry] = []
        for (idx, m) in matches.enumerated() {
            let time = ns.substring(with: m.range)
            let start = m.range.location + m.range.length
            let end = idx + 1 < matches.count ? matches[idx + 1].range.location : ns.length
            guard end > start else { continue }
            var desc = ns.substring(with: NSRange(location: start, length: min(end - start, 300)))
            desc = desc.replacingOccurrences(of: "\n", with: " ")
            desc = desc.trimmingCharacters(in: .whitespaces)
            while desc.contains("  ") { desc = desc.replacingOccurrences(of: "  ", with: " ") }
            if desc.isEmpty { continue }
            out.append(TraceEntry(id: out.count, time: time, text: String(desc.prefix(120))))
            if out.count >= 20 { break }
        }
        if out.isEmpty {
            let keys = ["已签收", "派送", "派件", "到达", "离开", "运输中", "揽收", "驿站", "快递柜", "取件", "预计", "发往"]
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.count < 4 || line.count > 60 { continue }
                if keys.contains(where: { line.contains($0) }) {
                    out.append(TraceEntry(id: out.count, time: "", text: line))
                }
                if out.count >= 12 { break }
            }
        }
        return out
    }
}
