import Foundation
import UIKit

/// App 深链：拼多多、淘宝都试「App 内页面」，失败才退回网页。
enum PddLink {
    struct Route {
        let name: String
        let url: String
    }

    /// 按平台分流
    static func open(platform: Platform, orderNo: String, itemID: String = "") {
        switch platform {
        case .pdd:
            openDefault(orderNo: orderNo)
        case .tb:
            openTaobao(orderNo: orderNo, itemID: itemID)
        case .jd:
            if let url = URL(string: "openapp.jdmobile://") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    /// 淘宝候选深链。实测「网页同路径」那条能进 App 的订单页，所以放第一位。
    static func tbCandidates(orderNo: String, itemID: String) -> [Route] {
        let sn = enc(orderNo)
        var list: [Route] = []
        list.append(Route(name: "① 订单详情（实测可用）", url: "taobao://trade.taobao.com/trade/detail/trade_item_detail.htm?bizOrderId=\(sn)"))
        if !itemID.isEmpty {
            let gid = enc(itemID)
            list.append(Route(name: "② 商品页", url: "taobao://item.taobao.com/item.htm?id=\(gid)"))
        }
        list.append(Route(name: "③ tbopen 订单详情", url: "tbopen://m.taobao.com/trade/detail?bizOrderId=\(sn)"))
        list.append(Route(name: "④ 我的订单", url: "taobao://order/list"))
        list.append(Route(name: "⑤ 网页版（兜底）", url: "https://buyertrade.taobao.com/trade/detail/trade_item_detail.htm?bizOrderId=\(sn)"))
        return list
    }

    /// 淘宝：优先 App 内页面，打不开再退回网页版
    static func openTaobao(orderNo: String, itemID: String) {
        let candidates = tbCandidates(orderNo: orderNo, itemID: itemID)
        guard let first = candidates.first, let url = URL(string: first.url) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            guard !ok, let last = candidates.last, let web = URL(string: last.url) else { return }
            UIApplication.shared.open(web, options: [:], completionHandler: nil)
        }
    }

    static func orderDetailURL(orderNo: String) -> URL? {
        let sn = enc(orderNo)
        return URL(string: "pinduoduo://com.xunmeng.pinduoduo/order.html?order_sn=\(sn)")
    }

    static func openDefault(orderNo: String) {
        guard let url = orderDetailURL(orderNo: orderNo) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            guard !ok, let root = URL(string: "pinduoduo://com.xunmeng.pinduoduo") else { return }
            UIApplication.shared.open(root, options: [:], completionHandler: nil)
        }
    }
}
