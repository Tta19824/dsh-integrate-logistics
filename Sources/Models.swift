import Foundation

enum Platform: String, CaseIterable, Identifiable, Codable {
    case pdd
    case tb
    case jd

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pdd: return "拼多多"
        case .tb: return "淘宝"
        case .jd: return "京东"
        }
    }

    var short: String {
        switch self {
        case .pdd: return "拼"
        case .tb: return "淘"
        case .jd: return "京"
        }
    }

    var loginURL: URL {
        switch self {
        case .pdd: return URL(string: "https://mobile.pinduoduo.com/login.html")!
        case .tb: return URL(string: "https://main.m.taobao.com/mytaobao/index.html")!
        case .jd: return URL(string: "https://plogin.m.jd.com/login/login")!
        }
    }

    var cookieDomainHints: [String] {
        switch self {
        case .pdd: return ["pinduoduo.com", "yangkeduo.com"]
        case .tb: return ["taobao.com", "tmall.com", "alicdn.com"]
        case .jd: return ["jd.com", "360buy.com"]
        }
    }

    /// 关键 cookie —— 只有拿到这些，才算真正登录成功。
    var essentialCookies: [String] {
        switch self {
        case .pdd: return ["PDDAccessToken"]
        case .tb: return ["cookie2", "unb"]
        case .jd: return ["pt_key", "pt_pin"]
        }
    }
}

enum OrderStatus: String, Codable {
    case unpaid
    case paid
    case shipped
    case completed
    case cancelled
    case refunding
    case unknown

    var label: String {
        switch self {
        case .unpaid: return "待付款"
        case .paid: return "待发货"
        case .shipped: return "待收货"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .refunding: return "退款中"
        case .unknown: return "其他"
        }
    }

    var symbol: String {
        switch self {
        case .unpaid: return "creditcard"
        case .paid: return "shippingbox"
        case .shipped: return "truck.box"
        case .completed: return "checkmark.seal"
        case .cancelled: return "xmark.circle"
        case .refunding: return "arrow.uturn.backward"
        case .unknown: return "questionmark.circle"
        }
    }

    static func parse(_ raw: String) -> OrderStatus {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .unknown }
        if text.contains("待付款") || text.contains("未付款") || text.contains("待支付") { return .unpaid }
        if text.contains("待发货") || text.contains("已付款") || text.contains("待成团") { return .paid }
        if text.contains("待收货") || text.contains("已发货") || text.contains("运输中") || text.contains("派送中") || text.contains("待取件") || text.contains("已到站") { return .shipped }
        if text.contains("已完成") || text.contains("已签收") || text.contains("交易成功") || text.contains("已收货") { return .completed }
        if text.contains("已取消") || text.contains("交易关闭") || text.contains("已关闭") { return .cancelled }
        if text.contains("退款") || text.contains("售后") { return .refunding }
        return .unknown
    }
}

struct Order: Identifiable, Codable, Equatable {
    var id: String
    var platform: Platform
    var orderNo: String
    var title: String
    var shopName: String
    var amount: String
    var status: OrderStatus
    var statusRaw: String
    var orderTime: String
    var logistics: String
    var pickupCode: String
    var updatedAt: Date

    static func makeID(platform: Platform, orderNo: String) -> String {
        "\(platform.rawValue):\(orderNo)"
    }
}
