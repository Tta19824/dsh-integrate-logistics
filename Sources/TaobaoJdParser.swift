import Foundation

/// 淘宝 / 京东的订单解析。
/// 两家的订单接口都是 JSON，字段名不一样但结构相似（一个对象里同时有订单号、商品名、金额、状态），
/// 所以这里统一用「按候选键名递归找对象」的办法，不写死某一家某一版的模型。
enum TaobaoJdParser {
    private static let tbNoKeys = ["bizOrderId", "bizOrderNo", "orderId", "mainOrderId", "orderNo", "tradeOrderId"]
    private static let tbTitleKeys = ["itemTitle", "auctionTitle", "itemName", "title", "productTitle", "foodName"]
    private static let tbAmountKeys = ["payAmount", "actualFee", "realPay", "totalFee", "payFee", "amount"]
    private static let tbStatusKeys = ["orderStatus", "statusDesc", "mainStatus", "status", "orderStatusText"]
    private static let tbShopKeys = ["shopName", "sellerNick", "shopTitle", "storeName"]
    private static let tbImageKeys = ["picUrl", "picPath", "itemPic", "imageUrl", "img"]
    private static let tbTimeKeys = ["orderTime", "createTime", "orderCreateTime", "gmtCreate", "createDate"]

    private static let jdNoKeys = ["orderId", "orderNo", "orderid", "jdOrderId"]
    private static let jdTitleKeys = ["skuName", "wareName", "productName", "itemName", "name", "title"]
    private static let jdAmountKeys = ["orderTotalPrice", "payPrice", "totalPrice", "orderPrice", "price", "amount"]
    private static let jdStatusKeys = ["orderStatus", "orderState", "statusName", "status", "state"]
    private static let jdShopKeys = ["shopName", "venderName", "storeName", "shopTitle"]
    private static let jdImageKeys = ["imageUrl", "imgUrl", "skuImage", "wareImage", "logo"]
    private static let jdTimeKeys = ["orderTime", "createTime", "orderDate", "submitTime"]

    static func parse(platform: Platform, text: String, payloadJSON: String) -> [Order] {
        guard let data = payloadJSON.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var out: [Order] = []
        var seen = Set<String>()

        for entry in entries {
            guard let body = entry["b"] as? String, body.count > 40,
                  let bodyData = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: bodyData) else { continue }
            walk(object, platform: platform, depth: 0, out: &out, seen: &seen)
        }

        out.sort { $0.updatedAt > $1.updatedAt }
        return out
    }

    // MARK: - 递归

    private static func walk(_ node: Any, platform: Platform, depth: Int, out: inout [Order], seen: inout Set<String>) {
        guard depth < 14 else { return }

        if let dict = node as? [String: Any] {
            if let order = makeOrder(dict, platform: platform) {
                if !seen.contains(order.id) {
                    seen.insert(order.id)
                    out.append(order)
                }
            }
            for (_, value) in dict {
                if value is [String: Any] || value is [Any] {
                    walk(value, platform: platform, depth: depth + 1, out: &out, seen: &seen)
                }
            }
            return
        }

        if let array = node as? [Any] {
            for value in array {
                if value is [String: Any] || value is [Any] {
                    walk(value, platform: platform, depth: depth + 1, out: &out, seen: &seen)
                }
            }
        }
    }

    private static func makeOrder(_ dict: [String: Any], platform: Platform) -> Order? {
        let noKeys = platform == .tb ? tbNoKeys : jdNoKeys
        let titleKeys = platform == .tb ? tbTitleKeys : jdTitleKeys
        let amountKeys = platform == .tb ? tbAmountKeys : jdAmountKeys
        let statusKeys = platform == .tb ? tbStatusKeys : jdStatusKeys
        let shopKeys = platform == .tb ? tbShopKeys : jdShopKeys
        let imageKeys = platform == .tb ? tbImageKeys : jdImageKeys
        let timeKeys = platform == .tb ? tbTimeKeys : jdTimeKeys

        // 订单号：必须是字符串或能转成字符串的数字，长度像订单号
        guard let rawNo = firstValue(dict, keys: noKeys) else { return nil }
        let orderNo = stringValue(rawNo)
        guard orderNo.count >= 6, orderNo.count <= 40, orderNo.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil else {
            return nil
        }

        // 商品名：没有标题的对象多半是统计/配置，直接跳过
        guard let rawTitle = firstValue(dict, keys: titleKeys) else { return nil }
        let title = cleanText(stringValue(rawTitle))
        guard title.count >= 2 else { return nil }

        let statusRaw = firstValue(dict, keys: statusKeys).map { stringValue($0) } ?? ""
        let amount = firstValue(dict, keys: amountKeys).map { normalizeAmount(stringValue($0)) } ?? ""
        let shop = firstValue(dict, keys: shopKeys).map { cleanText(stringValue($0)) } ?? ""
        let image = firstValue(dict, keys: imageKeys).map { normalizeURL(stringValue($0)) } ?? ""
        let orderTime = firstValue(dict, keys: timeKeys).map { normalizeTime(stringValue($0)) } ?? ""

        return Order(
            id: Order.makeID(platform: platform, orderNo: orderNo),
            platform: platform,
            orderNo: orderNo,
            title: title,
            shopName: shop,
            amount: amount,
            status: OrderStatus.parse(statusRaw),
            statusRaw: statusRaw,
            orderTime: orderTime,
            logistics: "",
            pickupCode: "",
            imageURL: image,
            updatedAt: Date()
        )
    }

    // MARK: - 小工具

    private static func firstValue(_ dict: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dict[key] {
                if value is NSNull { continue }
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeAmount(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains(".") { return trimmed }
        // 纯整数：淘宝/京东都用「分」的地方极少，但超过 6 位基本是分
        if let cents = Int(trimmed), trimmed.count >= 6 {
            return String(format: "%.2f", Double(cents) / 100.0)
        }
        return trimmed
    }

    private static func normalizeURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("http://") { return "https://" + trimmed.dropFirst(7) }
        return trimmed
    }

    private static func normalizeTime(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        if let number = Double(trimmed), trimmed.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil, !trimmed.contains("-") {
            var seconds = number
            if number > 3_000_000_000 { seconds = number / 1000.0 }  // 毫秒
            let date = Date(timeIntervalSince1970: seconds)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy/M/d HH:mm"
            return formatter.string(from: date)
        }

        // "2026-11-01 12:00:00" / "2026/11/01 12:00" 统一成 2026/11/1 12:00
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm"] {
            input.dateFormat = pattern
            if let date = input.date(from: trimmed) {
                let output = DateFormatter()
                output.locale = Locale(identifier: "en_US_POSIX")
                output.dateFormat = "yyyy/M/d HH:mm"
                return output.string(from: date)
            }
        }
        return trimmed
    }
}
