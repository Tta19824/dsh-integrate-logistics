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
            openJD(orderNo: orderNo)
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

    /// 京东候选深链（virtual 路由）
    static func jdCandidates(orderNo: String) -> [Route] {
        let detail = "https://trade.m.jd.com/order/n_detail_jdm.shtml?deal_id=\(orderNo)"
        let list = "https://order.m.jd.com/orderList/1"
        var out: [Route] = []
        out.append(Route(name: "① 订单详情（virtual + m）", url: virtual(detail)))
        out.append(Route(name: "② 订单详情（orderDetail）", url: virtual("https://order.m.jd.com/orderDetail?orderId=\(orderNo)")))
        out.append(Route(name: "③ 我的订单列表", url: virtual(list)))
        out.append(Route(name: "④ 只唤起京东（兜底）", url: "openapp.jdmobile://"))
        out.append(Route(name: "⑤ 网页版（兜底）", url: detail))
        return out
    }

    /// 京东 App 路由：openapp.jdmobile://virtual?params={...}
    static func virtual(_ target: String) -> String {
        let json = "{\"category\":\"jump\",\"des\":\"m\",\"url\":\"\(target)\",\"sourceType\":\"jump\"}"
        return "openapp.jdmobile://virtual?params=" + enc(json)
    }

    static func openJD(orderNo: String) {
        tryRoutes(jdCandidates(orderNo: orderNo), index: 0)
    }

    /// 依次尝试，打不开才换下一个
    static func tryRoutes(_ list: [Route], index: Int) {
        guard index < list.count, let url = URL(string: list[index].url) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok { tryRoutes(list, index: index + 1) }
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
