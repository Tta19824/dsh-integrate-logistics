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
        if let carrier = HTMLTools.firstMatch(#"承运人\s*[:：]?\s*([^\s，,；;]{2,12})"#, in: text) {
            out.carrier = carrier
        }

        // 时间线：一行是日期（可能带周几和时间），下一行是描述
        var lastDate = ""
        var id = 0
        var i = 0
        while i < lines.count {
            let line = lines[i]
            var timeText = ""

            if let dateRange = line.range(of: #"^20\d{2}-\d{2}-\d{2}"#, options: .regularExpression) {
                let date = String(line[dateRange])
                lastDate = date
                if let timeRange = line.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression) {
                    timeText = date + " " + String(line[timeRange])
                } else {
                    timeText = date
                }
            } else if line.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil {
                timeText = lastDate.isEmpty ? line : lastDate + " " + line
            }

            if !timeText.isEmpty, i + 1 < lines.count {
                let desc = lines[i + 1]
                let isDate = desc.range(of: #"^20\d{2}-\d{2}-\d{2}"#, options: .regularExpression) != nil
                let isTime = desc.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil
                if !isDate, !isTime, desc.count >= 2, eventWords.contains(where: { desc.contains($0) }) {
                    id += 1
                    out.events.append(ShipEvent(id: id, time: timeText, desc: desc))
                    i += 2
                    continue
                }
            }
            i += 1
        }

        if let first = out.events.first {
            out.statusRaw = String(first.desc.prefix(6))
        }
        return out
    }
}
