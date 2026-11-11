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

    static func parse(platform: Platform, text: String, payloadJSON: String, html: String = "") -> [Order] {
        let fromJSON = parseJSON(platform: platform, payloadJSON: payloadJSON)
        if !fromJSON.isEmpty { return fromJSON }
        let fromHTML = parseHTML(platform: platform, html: html)
        if !fromHTML.isEmpty { return fromHTML }
        return parseText(platform: platform, text: text)
    }

    // MARK: - 接口 JSON

    private static func parseJSON(platform: Platform, payloadJSON: String) -> [Order] {
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

    // MARK: - PC 订单页 HTML

    /// 淘宝电脑版订单页是服务端渲染的：订单号只在 HTML 的链接里，
    /// 商品名/店铺/价格在附近的节点里。按订单号切开 HTML，取每块里的字段。
    static func parseHTML(platform: Platform, html: String) -> [Order] {
        guard html.count > 200 else { return [] }

        var ids: [String] = []
        var seenID = Set<String>()
        let patterns = ["bizOrderId[=%3D](\\d{8,})", "orderId[=%3D](\\d{8,})", "order_id=([0-9]{8,})"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = html as NSString
            let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges > 1 {
                let value = ns.substring(with: match.range(at: 1))
                if !seenID.contains(value) {
                    seenID.insert(value)
                    ids.append(value)
                }
            }
            if !ids.isEmpty { break }
        }
        guard !ids.isEmpty else { return [] }

        let ns = html as NSString
        var out: [Order] = []
        var seen = Set<String>()

        for (index, orderNo) in ids.enumerated() {
            // 找到这个订单号在 HTML 里的位置，取前后一段
            guard let range = html.range(of: orderNo) else { continue }
            let location = ns.range(of: String(html[range])).location
            let start = max(0, location - 3000)
            let length = min(ns.length - start, 6000)
            let window = ns.substring(with: NSRange(location: start, length: length))

            let title = firstMatch(window, pattern: "(?:title|alt)=\"([^\"]{8,80})\"") ?? ""
            guard title.count >= 4 else { continue }

            let shop = firstMatch(window, pattern: "([\\u4e00-\\u9fa5A-Za-z0-9·]{2,20}(?:旗舰店|专营店|专卖店|企业店|工厂店|商行|店铺))") ?? ""
            let price = firstMatch(window, pattern: "(?:实付款[^0-9]{0,16})?([0-9]+\\.[0-9]{1,2})") ?? ""
            let statusRaw = statusWord(in: window)
            let image = firstMatch(window, pattern: "src=\"(//[^\"]+?\\.(?:jpg|png|webp)[^\"]*)\"") ?? ""
            let time = firstMatch(window, pattern: "([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}(?::[0-9]{2})?)") ?? ""

            let id = Order.makeID(platform: platform, orderNo: orderNo)
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            out.append(
                Order(
                    id: id,
                    platform: platform,
                    orderNo: orderNo,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    shopName: shop,
                    amount: price,
                    status: OrderStatus.parse(statusRaw),
                    statusRaw: statusRaw,
                    orderTime: normalizeTime(time),
                    logistics: "",
                    pickupCode: "",
                    imageURL: normalizeURL(image),
                    updatedAt: Date()
                )
            )
            if out.count >= 40 { break }
        }

        out.sort { $0.orderNo > $1.orderNo }
        return out
    }

    // MARK: - 页面文本兜底

    private static let tbTags: Set<String> = [
        "退货宝", "极速退款", "7天无理由退货", "7天无理由退换", "大促价保", "7天价保", "15天价保",
        "假一赔四", "假一赔十", "破损包退", "食品安全理赔", "慢必赔", "过敏包退", "赠品",
        "含包装/配送费", "不支持7天无理由", "公益宝贝", "运费险", "官方立减", "政府补贴"
    ]

    private static let tbStatuses: [String: OrderStatus] = [
        "待付款": .unpaid, "等待买家付款": .unpaid, "买家已付款": .paid, "待发货": .paid,
        "卖家已发货": .shipped, "待收货": .shipped, "已签收": .shipped, "运输中": .shipped,
        "交易成功": .completed, "已完成": .completed, "待评价": .completed,
        "交易关闭": .cancelled, "已取消": .cancelled,
        "退款成功": .refunding, "退款中": .refunding
    ]

    /// 淘宝电脑版订单页的 innerText 是「店铺 / 状态 / 标题 / 标签… / ￥ / 单价 / ×1 / 实付款 / ￥ / 金额 / 按钮」这样的块。
    /// 用「实付款 / 应付款 / 合计」做锚点向前回溯找标题、状态、店铺，比顺着状态往下猜可靠。
    static func parseText(platform: Platform, text: String) -> [Order] {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [Order] = []
        var seen = Set<String>()

        func isMoney(_ s: String) -> Bool {
            s.range(of: #"^[0-9]+(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil
        }

        func amountAfter(_ index: Int) -> String {
            var j = index + 1
            var guardCount = 0
            while j < lines.count && guardCount < 4 {
                let v = lines[j]
                if v == "￥" || v == "¥" { j += 1; guardCount += 1; continue }
                if isMoney(v) { return v }
                return ""
            }
            return ""
        }

        let anchors = lines.indices.filter { lines[$0] == "实付款" || lines[$0] == "应付款" || lines[$0] == "合计" }

        for anchor in anchors {
            let paid = amountAfter(anchor)
            guard !paid.isEmpty else { continue }

            // 价格区：向前最近的 ×N，再取其前面的金额
            var priceIndex = -1
            var k = anchor - 1
            var steps = 0
            while k >= 0 && steps < 14 {
                if lines[k].hasPrefix("×") || lines[k].hasPrefix("x") { priceIndex = k; break }
                k -= 1
                steps += 1
            }

            var titleIndex = -1
            var scan = (priceIndex > 0 ? priceIndex : anchor) - 1
            steps = 0
            while scan >= 0 && steps < 24 {
                let v = lines[scan]
                let skip = v == "￥" || v == "¥" || isMoney(v) || tbTags.contains(v)
                    || v.hasPrefix("共") || v.contains("件") || v.contains("包邮")
                    || v.hasPrefix("承诺") || v.hasPrefix("预计")
                if !skip && v.count >= 4 { titleIndex = scan; break }
                scan -= 1
                steps += 1
            }
            guard titleIndex >= 0 else { continue }

            let title = lines[titleIndex]

            // 状态：标题往上找
            var statusRaw = ""
            var statusIndex = -1
            var s = titleIndex - 1
            steps = 0
            while s >= 0 && steps < 8 {
                if tbStatuses[lines[s]] != nil { statusRaw = lines[s]; statusIndex = s; break }
                s -= 1
                steps += 1
            }

            // 店铺：状态往上 1~2 行（连锁店会多一行分店名）
            var shop = ""
            if statusIndex > 0 {
                let up1 = lines[statusIndex - 1]
                let up2 = statusIndex >= 2 ? lines[statusIndex - 2] : ""
                if !up2.isEmpty && !isMoney(up2) && up2 != "￥" && (up1.hasSuffix("店") || up1.contains("旗舰") || up1.contains("专营")) && up1.count <= 22 && up2.count <= 26 {
                    shop = up2
                } else {
                    shop = up1
                }
                if shop == "￥" || isMoney(shop) { shop = "" }
            }

            let orderNo = "TB\(Self.stableHash(title + "|" + paid + "|" + shop))"
            guard !seen.contains(orderNo) else { continue }
            seen.insert(orderNo)

            out.append(Order(
                id: Order.makeID(platform: platform, orderNo: orderNo),
                platform: platform,
                orderNo: orderNo,
                title: title,
                shopName: shop,
                amount: paid,
                status: tbStatuses[statusRaw] ?? .unknown,
                statusRaw: statusRaw,
                orderTime: "",
                logistics: "",
                pickupCode: "",
                carrier: "",
                imageURL: "",
                goodsID: "",
                updatedAt: Date()
            ))
        }

        out.sort { $0.updatedAt > $1.updatedAt }
        return out
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let value = ns.substring(with: match.range(at: 1))
        return value.isEmpty ? nil : value
    }

    private static func statusWord(in text: String) -> String {
        let words = ["等待买家付款", "买家已付款", "卖家已发货", "交易成功", "交易关闭", "已签收", "退款成功", "退款中", "待发货", "待收货"]
        for word in words where text.contains(word) { return word }
        return ""
    }

    private static func stableHash(_ text: String) -> Int {
        var hash = 5381
        for scalar in text.unicodeScalars {
            hash = (hash &* 33) &+ Int(scalar.value)
        }
        return hash
    }
}
