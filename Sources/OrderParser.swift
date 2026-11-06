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

    static func ranges(of pattern: String, in text: String) -> [NSRange] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map { $0.range }
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

    static func slice(_ text: String, center: Int, before: Int, after: Int) -> String {
        let ns = text as NSString
        let start = max(0, center - before)
        let end = min(ns.length, center + after)
        guard start < end else { return "" }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}

/// 拼多多订单页是一堆服务端渲染的 HTML，结构随时会变。
/// 这里不写死选择器，而是围绕「订单号」定位，再在前后窗口里找商品名 / 状态 / 金额。
enum PinduoduoParser {
    private static let statusWords = [
        "待发货", "待收货", "待付款", "已完成", "已取消", "已签收",
        "交易成功", "交易关闭", "退款中", "待成团", "拼单成功", "待评价"
    ]

    static func parse(html: String, now: Date = Date()) -> [Order] {
        let text = HTMLTools.strip(html)
        let anchors = orderAnchors(in: html, plainText: text)
        var orders: [Order] = []
        var seen = Set<String>()

        for anchor in anchors {
            guard !seen.contains(anchor.orderNo) else { continue }
            seen.insert(anchor.orderNo)

            let window = HTMLTools.slice(text, center: anchor.plainIndex, before: 600, after: 900)
            let statusRaw = statusWords.first { window.contains($0) } ?? ""
            let amount = HTMLTools.firstMatch("(?:¥|￥|实付|实收款)\\s*([0-9]+(?:\\.[0-9]{1,2})?)", in: window) ?? ""
            let title = guessTitle(from: window)
            let time = HTMLTools.firstMatch("(20[0-9]{2}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}(?::[0-9]{2})?)", in: window) ?? ""

            let order = Order(
                id: Order.makeID(platform: .pdd, orderNo: anchor.orderNo),
                platform: .pdd,
                orderNo: anchor.orderNo,
                title: title,
                shopName: "",
                amount: amount,
                status: OrderStatus.parse(statusRaw),
                statusRaw: statusRaw.isEmpty ? "未识别" : statusRaw,
                orderTime: time,
                logistics: "",
                pickupCode: "",
                updatedAt: now
            )
            orders.append(order)
        }
        return orders
    }

    private struct Anchor {
        let orderNo: String
        let plainIndex: Int
    }

    private static func orderAnchors(in html: String, plainText: String) -> [Anchor] {
        var anchors: [Anchor] = []

        // 形如：订单号：240101-123456789012345
        let patterns = [
            "订单号[：: ]*([0-9\\-]{8,})",
            "订单编号[：: ]*([0-9\\-]{8,})",
            "\"orderSn\"\\s*:\\s*\"([0-9\\-]{8,})\"",
            "\"order_sn\"\\s*:\\s*\"([0-9\\-]{8,})\""
        ]
        let ns = plainText as NSString
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = re.matches(in: plainText, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
                guard r.location != NSNotFound else { continue }
                let orderNo = ns.substring(with: r)
                anchors.append(Anchor(orderNo: orderNo, plainIndex: m.range.location))
            }
        }
        return anchors.sorted { $0.plainIndex < $1.plainIndex }
    }

    private static func guessTitle(from window: String) -> String {
        let lines = window
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 6 }

        let banned = ["订单号", "订单编号", "实付", "合计", "运费", "优惠", "查看物流", "确认收货", "再次购买"]
        for line in lines {
            if banned.contains(where: { line.contains($0) }) { continue }
            if line.allSatisfy({ $0.isNumber || $0 == "-" || $0 == ":" }) { continue }
            return String(line.prefix(60))
        }
        return ""
    }
}
