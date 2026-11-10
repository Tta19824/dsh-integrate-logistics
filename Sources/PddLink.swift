import Foundation
import UIKit

/// 拼多多 App 的深链路由。内部路由文档一直没有，只能靠试：
/// 每个 template 里的 {sn} 会替换成订单号，{url} 会替换成编码后的网页地址。
enum PddLink {
    struct Route {
        let name: String
        let template: String
    }

    static let routes: [Route] = [
        Route(name: "order.html（网页同路径）", template: "pinduoduo://com.xunmeng.pinduoduo/order.html?order_sn={sn}"),
        Route(name: "order_detail", template: "pinduoduo://com.xunmeng.pinduoduo/order_detail?order_sn={sn}"),
        Route(name: "orders.html", template: "pinduoduo://com.xunmeng.pinduoduo/orders.html?order_sn={sn}"),
        Route(name: "open_url + 网页地址", template: "pinduoduo://com.xunmeng.pinduoduo/open_url?url={url}"),
        Route(name: "order_detail + 网页 fallback", template: "pinduoduo://com.xunmeng.pinduoduo/order_detail?order_sn={sn}&fallback={url}"),
        Route(name: "order（简写）", template: "pinduoduo://com.xunmeng.pinduoduo/order?order_sn={sn}")
    ]

    static func url(_ route: Route, orderNo: String) -> URL? {
        let sn = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
        let web = "https://mobile.pinduoduo.com/order.html?order_sn=\(sn)"
        let encoded = web.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? web
        let raw = route.template
            .replacingOccurrences(of: "{sn}", with: sn)
            .replacingOccurrences(of: "{url}", with: encoded)
        return URL(string: raw)
    }

    static func open(_ route: Route, orderNo: String) {
        guard let url = url(route, orderNo: orderNo) else { return }
        UIApplication.shared.open(url, options: [:]) { _ in }
    }

    /// 卡片右侧点击用：先按最像的那条走，打不开再退到首页。
    static func openDefault(orderNo: String) {
        var urls: [URL] = []
        for route in routes.prefix(2) {
            if let u = url(route, orderNo: orderNo) { urls.append(u) }
        }
        if let root = URL(string: "pinduoduo://com.xunmeng.pinduoduo") { urls.append(root) }
        openFirst(urls)
    }

    private static func openFirst(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let rest = Array(urls.dropFirst())
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok { openFirst(rest) }
        }
    }
}
