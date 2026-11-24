import Foundation

/// 老版京东订单详情页（`https://details.jd.com/normal/item.action?orderid=…&PassKey=…`）的解析。
///
/// 这一页才是「信息齐全」的那一页：提货码/取件码、运单号、承运人、物流时间线全在一屏之内。
/// 新版订单中心（`order.jd.com/center/viewOrder.action?orderId=…`）只有一句
/// 「您的订单在京东【…驿站】投递完成，请上门提货」——拿错页就会得到「物流详情数据不对」。
enum JdPCDetail {
    struct Parsed {
        var pickupCode = ""
        var trackingNo = ""
        var carrier = ""
        var statusRaw = ""
        var events: [ShipEvent] = []
    }

    /// 时间线里值得当成「进展」的描述词。页头也有日期（期望自提日期之类），
    /// 不加这层过滤会把收货地址当成一条物流。
    private static let eventWords = [
        "已签收", "签收", "待取件", "取件", "派送", "配送", "运输", "出库", "提交订单",
        "发货", "揽收", "到达", "投递", "自提", "提醒", "异常"
    ]

    /// 详情页的状态行都很短（「已签收 取件码 15-6-2127」「待取件」「派送中」）。
    /// 描述行长得多，单独成段的描述不带状态词，靠长度区分。
    private static func isStatusLine(_ s: String) -> Bool {
        guard s.count <= 24 else { return false }
        return eventWords.contains { s.contains($0) }
    }

    static func timeOf(_ line: String, lastDate: inout String) -> String? {
        if let r = line.range(of: #"^20\d{2}-\d{2}-\d{2}"#, options: .regularExpression) {
            let date = String(line[r])
            lastDate = date
            if let t = line.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression) {
                return date + " " + String(line[t])
            }
            return date
        }
        if line.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil {
            return lastDate.isEmpty ? line : lastDate + " " + line
        }
        return nil
    }

    static func parse(_ text: String) -> Parsed {
        var out = Parsed()
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 取件码：时间线里写的是「已签收 取件码 15-6-2127」；提货码栏位也认，但常常是空的
        if let code = HTMLTools.firstMatch(#"(?:取件码|提货码|自提码)\s*[:：]?\s*([0-9A-Za-z]{1,4}(?:-[0-9A-Za-z]{1,6}){1,3})"#, in: text),
           code.count >= 5 {
            out.pickupCode = code
        }
        if let no = HTMLTools.firstMatch(#"运单号\s*[:：]?\s*([A-Za-z0-9]{8,25})"#, in: text) {
            out.trackingNo = no
        }
        // 详情页「配送信息」里写的是「配送方式：京东快递」，承运人栏有时是「承运人：京东快递」
        if let carrier = HTMLTools.firstMatch(#"(?:承运人|配送方式)\s*[:：]?\s*([^\s，,；;()（）]{2,12})"#, in: text) {
            out.carrier = carrier
        }

        // 第一遍：认出所有「整行就是时间」的行，得到每行的完整时间。
        var lastDate = ""
        var timeAt: [Int: String] = [:]
        for (i, line) in lines.enumerated() {
            var d = lastDate
            if let t = timeOf(line, lastDate: &d) {
                lastDate = d
                timeAt[i] = t
            }
        }

        // 详情页有一类行是「14:14:38 正在长途运输中…」，日期单独写在**下一行**。
        // 倒着扫一遍，记住每行之后最近的一个完整日期，给这类行补日子。
        var upcomingDate: [Int: String] = [:]
        var upcoming = ""
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            if let t = timeAt[i], t.count >= 10 { upcoming = String(t.prefix(10)) }
            upcomingDate[i] = upcoming
        }

        var usedStatus = Set<Int>()
        var events: [ShipEvent] = []
        var id = 0

        for (i, line) in lines.enumerated() {
            // A. 自带时间的描述行（时间 + 空格 + 正文）：描述本身就是内容，不再找状态行。
            if let r = line.range(of: #"^\d{2}:\d{2}:\d{2}\s+"#, options: .regularExpression) {
                let timePart = String(line[r]).trimmingCharacters(in: .whitespaces)
                let desc = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if desc.count >= 4 {
                    let date = upcomingDate[i] ?? ""
                    id += 1
                    events.append(ShipEvent(id: id,
                                            time: date.isEmpty ? timePart : date + " " + timePart,
                                            desc: desc))
                }
                continue
            }

            // B. 纯时间行：状态行通常紧挨在上面（京东是「状态在上、时间在下」），
            //    少数情况在下面（「派送中」写在时间之后的那一行）。
            guard let time = timeAt[i] else { continue }
            var statusIndex: Int?
            for candidate in [i - 1, i + 1] {
                guard candidate >= 0, candidate < lines.count,
                      !usedStatus.contains(candidate),
                      timeAt[candidate] == nil else { continue }
                if isStatusLine(lines[candidate]) { statusIndex = candidate; break }
            }
            guard let si = statusIndex else { continue }
            usedStatus.insert(si)

            var status = lines[si]
            var extra = ""
            // 「已签收 取件码 15-6-2127」：状态要干净，取件码单独带回描述里
            if let r = status.range(of: "取件码") {
                extra = String(status[r.lowerBound...])
                status = String(status[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            // 时间下一行如果是一段描述，拼进去（「派送中」+「您的订单正在配送途中…」）
            let next = i + 1
            if next < lines.count, next != si, timeAt[next] == nil,
               !isStatusLine(lines[next]),
               lines[next].count >= 8,
               lines[next].range(of: #"^\d{2}:\d{2}:\d{2}"#, options: .regularExpression) == nil {
                let cand = lines[next]
                extra = extra.isEmpty ? cand : extra + " " + cand
            }
            let desc = extra.isEmpty ? status : "\(status) \(extra)"
            id += 1
            events.append(ShipEvent(id: id, time: time, desc: desc))
        }

        // 新的在最上面：卡片上的物流条只显示第一条，顺序错了就会显示「商品出库」这种最旧的
        events.sort { timeKey($0.time) > timeKey($1.time) }
        // id 重新编号，保证第一眼看到的是最新一条
        out.events = events.enumerated().map { ShipEvent(id: $0.offset + 1, time: $0.element.time, desc: $0.element.desc) }
        if let first = out.events.first {
            out.statusRaw = String(first.desc.prefix(6))
        }
        return out
    }

    /// 「2026-11-17 10:49:16」→ 可比大小的数字串；只有时间的补一个 0，排到最后去。
    private static func timeKey(_ s: String) -> String {
        let digits = s.filter { $0.isNumber }
        return digits.count >= 14 ? digits : "0" + digits
    }
}
