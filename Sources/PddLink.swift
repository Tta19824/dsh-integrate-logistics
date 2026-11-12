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

    /// 淘宝候选深链，按「最可能打开 App 内订单/商品页」排序。
    static func tbCandidates(orderNo: String, itemID: String) -> [Route] {
        let sn = enc(orderNo)
        var list: [Route] = []
        if !itemID.isEmpty {
            let gid = enc(itemID)
            list.append(Route(name: "taobao://item（商品页）", url: "taobao://item.taobao.com/item.htm?id=(gid)"))
            list.append(Route(name: "taobao://detail（商品页）", url: "taobao://detail?itemId=(gid)"))
        }
        list.append(Route(name: "tbopen://trade/detail（订单详情）", url: "tbopen://m.taobao.com/trade/detail?bizOrderId=(sn)"))
        list.append(Route(name: "taobao://trade/detail（订单详情）", url: "taobao://trade/detail?bizOrderId=(sn)"))
        list.append(Route(name: "taobao://m.taobao 详情", url: "taobao://m.taobao.com/trade/detail?bizOrderId=(sn)"))
        list.append(Route(name: "taobao://order（订单列表）", url: "taobao://order/list"))
        list.append(Route(name: "网页版（兜底）", url: "https://buyertrade.taobao.com/trade/detail/trade_item_detail.htm?bizOrderId=(sn)"))
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
        return URL(string: "pinduoduo://com.xunmeng.pinduoduo/order.html?order_sn=(sn)")
    }

    static func openDefault(orderNo: String) {
        guard let url = orderDetailURL(orderNo: orderNo) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            guard !ok, let root = URL(string: "pinduoduo://com.xunmeng.pinduoduo") else { return }
            UIApplication.shared.open(root, options: [:], completionHandler: nil)
        }
    }
}
