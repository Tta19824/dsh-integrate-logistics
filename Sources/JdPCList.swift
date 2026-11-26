import Foundation

/// 京东电脑版订单列表解析。
///
/// 路子：`https://order.jd.com/center/list.action` 是**服务端渲染**的页面，
/// 登录态（`thor`+`pin`）在 cookie 里，返回的 HTML 里直接就有全部订单。
/// 好处是：不碰手机版那套 `pt_key` 会话，也就不会被手机 web 的风控连坐。
///
/// 解析方式故意做得「粗」：只靠 `订单号：<数字>` 切块，再在每块里找状态词、金额、商品名。
/// 京东改版时最容易坏的是样式类名，而 `订单号` 这三个字几乎不会变。
enum JdPCList {
    struct Row {
        let orderNo: String
        let status: OrderStatus
        let statusRaw: String
        let title: String
        let amount: String
        let dateText: String
    }

    /// 状态词表：先命中的优先。京东 PC 列表里常见的是「等待付款/等待出库/等待收货/已完成/已取消」
    private static let statusWords: [(String, OrderStatus)] = [
        ("等待付款", .unpaid), ("等待支付", .unpaid), ("未付款", .unpaid), ("待付款", .unpaid),
        ("等待出库", .paid), ("待发货", .paid), ("已付款", .paid),
        ("等待收货", .shipped), ("已发货", .shipped), ("运输中", .shipped), ("派送中", .shipped),
        ("待取件", .shipped), ("已到站", .shipped), ("请上门自提", .shipped), ("上门自提", .shipped),
        ("待自提", .shipped), ("请上门提货", .shipped), ("已投递", .shipped),
        ("已完成", .completed), ("已签收", .completed), ("交易成功", .completed), ("已收货", .completed),
        ("已取消", .cancelled), ("交易关闭", .cancelled), ("已关闭", .cancelled),
        ("退款", .refunding), ("售后", .refunding), ("退货", .refunding), ("换货", .refunding), ("返修", .refunding)
    ]

    /// 终态词：只要卡片上出现，就压过「待取件/请上门自提」这类过程词。
    /// 注意不放「退款/售后」——活动订单卡片底部一直有「申请退款」按钮，会被误判。
    private static let terminalWords: [(String, OrderStatus)] = [
        ("已完成", .completed), ("交易成功", .completed), ("已收货", .completed),
        ("已取消", .cancelled), ("交易关闭", .cancelled), ("已关闭", .cancelled)
    ]

    /// 从 HTML 里解析订单。没解析到就返回空数组（调用方据此走别的路）。
    static func parse(html: String) -> [Row] {
        guard !html.isEmpty else { return [] }
        let chunks = splitByOrderNo(html)
        var rows: [Row] = []
        var seen = Set<String>()
        for chunk in chunks {
            guard let orderNo = chunk.orderNo, !seen.contains(orderNo) else { continue }
            let text = HTMLTools.strip(chunk.body)
            let status = statusIn(HTMLTools.strip(chunk.afterNo)) ?? statusIn(text)
            let title = titleIn(html: chunk.body, text: HTMLTools.strip(chunk.afterNo))
            let amount = amountIn(text)
            let date = dateIn(text)
            // 三个关键字段都没有的块，多半是页面别处的「订单号」字样（比如帮助提示），丢掉
            if title.isEmpty && status == nil && amount.isEmpty { continue }
            seen.insert(orderNo)
            rows.append(Row(
                orderNo: orderNo,
                status: status?.1 ?? .unknown,
                statusRaw: status?.0 ?? "",
                title: title,
                amount: amount,
                dateText: date
            ))
        }
        return rows
    }

    /// 只有纯文本时（WebView 渲染出来的 innerText）也能解析。
    static func parse(text: String) -> [Row] {
        guard !text.isEmpty else { return [] }
        var rows: [Row] = []
        var seen = Set<String>()
        for chunk in splitByOrderNo(text) {
            guard let orderNo = chunk.orderNo, !seen.contains(orderNo) else { continue }
            let status = statusIn(chunk.afterNo) ?? statusIn(chunk.body)
            var amount = amountIn(chunk.afterNo)
            if amount.isEmpty { amount = amountIn(chunk.body) }
            let title = plainTitleIn(chunk.afterNo.isEmpty ? chunk.body : chunk.afterNo, orderNo: orderNo)
            if title.isEmpty && status == nil && amount.isEmpty { continue }
            seen.insert(orderNo)
            rows.append(Row(
                orderNo: orderNo,
                status: status?.1 ?? .unknown,
                statusRaw: status?.0 ?? "",
                title: title,
                amount: amount,
                dateText: dateIn(chunk.body)
            ))
        }
        return rows
    }

    // MARK: - 切块

    private struct Chunk {
        let orderNo: String?
        let body: String
        /// 从这个订单号开始往后的内容。状态词/标题要优先在这里面找 ——
        /// `body` 前面那 400 字是**上一单的尾巴和页面导航**，里面全是「待付款/已完成」这类 tab 文字，
        /// 拿它判状态会把「请上门自提」误判成「待付款」（2026-11-19 实测）。
        let afterNo: String
    }

    /// 以 `订单号：<8~25 位数字>` 为界把整页切开。
    /// 每块从「上一个订单号」到「这个订单号之前」—— 这样日期/状态都在块里。
    private static func splitByOrderNo(_ text: String) -> [Chunk] {
        guard let re = try? NSRegularExpression(pattern: "订单号[：:\\s]*(\\d{8,25})", options: []) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var chunks: [Chunk] = []
        // 第一块的头部（第一个订单号之前的内容）单独留着，里面可能有日期
        for (idx, m) in matches.enumerated() {
            let noRange = m.range(at: 1)
            let orderNo = noRange.location == NSNotFound ? nil : ns.substring(with: noRange)
            let start = m.range.location
            let end = idx + 1 < matches.count ? matches[idx + 1].range.location : ns.length
            guard end > start else { continue }
            var body = ns.substring(with: NSRange(location: start, length: end - start))
            let afterNo = body
            // 往前带 400 字：日期、店铺名有时候在「订单号」前面
            let backStart = max(0, start - 400)
            if backStart < start {
                body = ns.substring(with: NSRange(location: backStart, length: start - backStart)) + body
            }
            chunks.append(Chunk(orderNo: orderNo, body: body, afterNo: afterNo))
        }
        return chunks
    }

    // MARK: - 字段

    private static func statusIn(_ text: String) -> (String, OrderStatus)? {
        // 先认「终态」词。以前这里只按 statusWords 的书写顺序扫，而「待取件/请上门自提」
        // 排在「已完成」前面 —— 一单已经确认收货了，卡片上还留着取件码/自提字样，
        // 就会被判成待收货，于是「已收货的单子还在订单页里挂着」（2026-11-26 用户实测）。
        for (word, status) in terminalWords where text.contains(word) {
            return (word, status)
        }
        for (word, status) in statusWords where text.contains(word) {
            return (word, status)
        }
        return nil
    }

    private static func amountIn(_ text: String) -> String {
        if let v = HTMLTools.firstMatch("[¥￥]\\s*([0-9][0-9,]*\\.?[0-9]{0,2})", in: text) {
            return "¥" + v
        }
        // 有的版式把金额写成「实付款 99.00 元」
        if let v = HTMLTools.firstMatch("(?:实付款|在线支付|应付总额|总金额)[：:\\s]*[¥￥]?\\s*([0-9][0-9,]*\\.?[0-9]{0,2})", in: text) {
            return "¥" + v
        }
        return ""
    }

    private static func dateIn(_ text: String) -> String {
        if let d = HTMLTools.firstMatch("(\\d{4}-\\d{2}-\\d{2}(?:\\s+\\d{2}:\\d{2}(?::\\d{2})?)?)", in: text) {
            return d
        }
        return HTMLTools.firstMatch("(\\d{2}-\\d{2}\\s+\\d{2}:\\d{2})", in: text) ?? ""
    }

    /// 商品名：优先取商品详情链接的文字（HTML 里最可靠）
    private static func titleIn(html: String, text: String) -> String {
        let patterns = [
            "href=\"[^\"]*item\\.(?:m\\.)?jd\\.com/\\d+\\.html\"[^>]*>([^<]{2,120})<",
            "class=\"p-name\"[^>]*>\\s*(?:<[^>]+>\\s*)*([^<]{2,120})<"
        ]
        for p in patterns {
            if let t = HTMLTools.firstMatch(p, in: html), !t.isEmpty {
                return clean(t)
            }
        }
        return plainTitleIn(text, orderNo: "")
    }

    /// 纯文本里的商品名：在候选行里挑**最长**的那条。
    /// 之前是「第一行不吵的」，于是把页头「你好，请登录 免费注册」当成了商品名（2026-11-19 实测）；
    /// 商品标题几乎总是这一块里最长的一行，而导航/按钮都很短。
    private static func plainTitleIn(_ text: String, orderNo: String) -> String {
        let noise = ["订单号", "等待付款", "待付款", "等待出库", "待发货", "等待收货", "待收货", "已完成",
                     "已取消", "售后", "退款", "再次购买", "查看物流", "订单详情", "删除订单", "评价",
                     "京东", "￥", "¥", "合计", "实付", "请登录", "免费注册", "桌面版", "购物车",
                     "我的订单", "订单中心", "导出订单", "近3个月订单", "物流信息", "操作", "金额",
                     "上一页", "下一页", "在线支付", "确认收货", "申请退款", "查看发票", "京ICP备",
                     "Copyright", "营业执照", "网络文化经营", "增值电信"]
        var best = ""
        for (index, raw) in text.split(separator: "\n").enumerated() {
            // 只看前 40 行：最后一块会一直伸到页脚，页脚那些「京公网安备…｜京ICP备…」又长又像标题
            if index > 40 { break }
            var line = clean(String(raw))
            guard line.count >= 4 else { continue }
            if !orderNo.isEmpty { line = line.replacingOccurrences(of: orderNo, with: " ") }
            if noise.contains(where: { line.contains($0) }) { continue }
            if line.contains("|") { continue }
            // 全是数字/符号的不要；日期、纯金额也排除
            let letters = line.filter { $0.isLetter || $0.isNumber }
            guard letters.count >= 3 else { continue }
            if line.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { continue }
            if line.count > best.count { best = line }
        }
        return String(best.prefix(60))
    }

    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
