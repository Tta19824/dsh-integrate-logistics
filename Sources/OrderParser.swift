import Foundation

enum HTMLTools {
    /// 鍘绘帀鏍囩銆佽剼鏈€佹牱寮忥紝鍘嬬缉绌虹櫧锛岀暀涓嬪彲璇绘枃鏈€?    static func strip(_ html: String) -> String {
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

/// 绋冲畾鐨勫瓧绗︿覆鍝堝笇锛圫wift 鐨?hashValue 姣忔鍚姩閮藉彉锛屼笉鑳芥嬁鏉ュ仛璁㈠崟涓婚敭锛?func stableHash(_ text: String) -> String {
    var hash: UInt64 = 5381
    for byte in text.utf8 {
        hash = (hash &* 33) &+ UInt64(byte)
    }
    return String(hash, radix: 16)
}

/// 鎷煎澶氳鍗曢〉鏄墠绔覆鏌撶殑绌哄３锛孒TML 閲屾病鏈夎鍗曟暟鎹€?/// 鎵€浠ヨВ鏋愬垎涓よ矾锛氫紭鍏堝悆 WebView 鎶撳埌鐨勬帴鍙?JSON锛岄€€鑰屾眰鍏舵鍚冩覆鏌撳悗鐨勭函鏂囨湰銆?enum PinduoduoParser {
    static let statusWords = [
        "寰呭彂璐?, "寰呮敹璐?, "寰呬粯娆?, "宸插畬鎴?, "宸插彇娑?, "宸茬鏀?,
        "浜ゆ槗鎴愬姛", "浜ゆ槗鍏抽棴", "閫€娆句腑", "寰呮垚鍥?, "鎷煎崟鎴愬姛", "寰呰瘎浠?,
        "寰呭彇浠?, "杩愯緭涓?, "娲鹃€佷腑", "宸插彂璐?
    ]

    // MARK: 鍏ュ彛

    static func parse(text: String, payloadJSON: String, now: Date = Date()) -> [Order] {
        let fromJSON = parsePayload(payloadJSON, now: now)
        if !fromJSON.isEmpty { return fromJSON }
        return parseText(text, now: now)
    }

    static func parse(html: String, now: Date = Date()) -> [Order] {
        parseText(HTMLTools.strip(html), now: now)
    }

    // MARK: 鎺ュ彛 JSON

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
        let statusRaw = prompt.isEmpty ? (code >= 0 ? "鐘舵€佺爜 \(code)" : "鏈瘑鍒?) : prompt

        var amount = firstString(dict, [
            "display_amount", "order_amount", "orderAmount", "pay_amount", "payAmount",
            "total_amount", "totalAmount", "amount"
        ]) ?? ""
        if let cents = dict["pay_amount_cent"] as? Int, amount.isEmpty {
            amount = String(cents)
        }
        amount = normalizeAmount(amount)

        var title = ""
        var shop = firstString(dict, ["mall_name", "mallName", "store_name", "storeName", "shop_name", "shopName"]) ?? ""
        if shop.isEmpty, let mall = dict["mall"] as? [String: Any] {
            shop = firstString(mall, ["mall_name", "mallName", "shop_name", "shopName"]) ?? ""
        }
        for key in ["order_goods", "orderGoods", "goods", "goods_list", "goodsList", "order_goods_list", "orderGoodsList", "items", "goods_info"] {
            guard let arr = dict[key] as? [[String: Any]], let first = arr.first else { continue }
            title = firstString(first, ["goods_name", "goodsName", "goods_title", "goodsTitle", "title", "name"]) ?? ""
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
            statusRaw: statusRaw.isEmpty ? "鏈瘑鍒? : statusRaw,
            orderTime: normalizeTime(time),
            logistics: "",
            pickupCode: "",
            updatedAt: now
        )
    }

    /// 骞冲彴鎺ュ彛閲岀殑閲戦鍩烘湰鏄€屽垎銆嶏紝鐣岄潰涓婅鏄剧ず鎴愪袱浣嶅皬鏁扮殑鍏冦€?    /// 宸茬粡鏄皬鏁扮殑鍘熸牱淇濈暀锛涚函鏁存暟鐨勯櫎浠?100銆?    private static func normalizeAmount(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["楼", "锟?] where s.hasPrefix(prefix) {
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

    /// 鎷煎澶氱殑鐘舵€佹槸鏁板瓧鐮侊紝浣嗘瘡鍗曡繕甯︿竴鍙?prompt锛堝厖鍊煎埌璐?/ 浜ゆ槗鎴愬姛 / 浜ゆ槗宸插彇娑堚€︼級锛?    /// prompt 鏇村噯锛屽厛鐢ㄥ畠锛岃涓嶅嚭鍐嶉€€鍥炴暟瀛楃爜銆?    static func pddStatus(code: Int, prompt: String) -> OrderStatus {
        if prompt.contains("鍙栨秷") || prompt.contains("鍏抽棴") { return .cancelled }
        if prompt.contains("閫€娆?) || prompt.contains("鍞悗") || prompt.contains("閫€璐?) { return .refunding }
        if prompt.contains("寰呮敹璐?) || prompt.contains("杩愯緭") || prompt.contains("娲鹃€?) || prompt.contains("寰呭彇浠?) { return .shipped }
        if prompt.contains("寰呭彂璐?) || prompt.contains("寰呮垚鍥?) { return .paid }
        if prompt.contains("寰呬粯娆?) || prompt.contains("寰呮敮浠?) { return .unpaid }
        if prompt.contains("鎴愬姛") || prompt.contains("鍒拌处") || prompt.contains("瀹屾垚") || prompt.contains("宸茬鏀?) { return .completed }
        switch code {
        case 0: return .unpaid
        case 1, 2, 3: return .shipped
        case 4, 5: return .completed
        case 6: return .refunding
        case 7: return .cancelled
        default: return .unknown
        }
    }

    // MARK: 娓叉煋鍚庣函鏂囨湰

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
            let amount = window.compactMap { HTMLTools.firstMatch("(?:楼|锟?\\s*([0-9]+(?:\\.[0-9]{1,2})?)", in: $0) }.first ?? ""
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
        let banned = ["璁㈠崟鍙?, "璁㈠崟缂栧彿", "瀹炰粯", "鍚堣", "杩愯垂", "浼樻儬", "鏌ョ湅鐗╂祦",
                      "纭鏀惰揣", "鍐嶆璐拱", "鐢宠鍞悗", "璇勪环", "鍒犻櫎", "鏇村", "鍏ㄩ儴"]
        for line in window.reversed() {
            guard line.count >= 6 else { continue }
            if banned.contains(where: { line.contains($0) }) { continue }
            if line.allSatisfy({ $0.isNumber || "-:锛毬ワ骏. ".contains($0) }) { continue }
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

    /// 取件码，例如「取件码：8-2-1234」
    static func pickupCode(from text: String) -> String {
        firstMatch("(?:取件码|提货码|取货码|取件号)[^0-9A-Za-z\\-]{0,8}([0-9A-Za-z\\-]{3,14})", in: text)
            ?? firstMatch("([0-9]{1,2}-[0-9]{1,2}-[0-9]{3,8})", in: text)
            ?? ""
    }

    /// 当前物流状态词
    static func statusWord(from text: String) -> String {
        let words = ["已签收", "派送中", "派件中", "待取件", "运输中", "已发货", "已揽收", "待发货", "待收货"]
        for w in text.components(separatedBy: "\n") {
            let line = w.trimmingCharacters(in: .whitespaces)
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

    /// 物流轨迹：形如「2026-11-07 11:05:16\n【盘锦市】快件离开…」
    static func trace(from text: String) -> [TraceEntry] {
        guard let re = try? NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2}") else { return [] }
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
        return out
    }
}
