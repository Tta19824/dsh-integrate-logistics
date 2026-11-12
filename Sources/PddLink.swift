import Foundation
import UIKit

/// 拼多多 App 深链：实测只有「网页同路径」这条能准确落到该订单的详情页，
/// 其余 order_detail / orders.html / open_url 都会停在「页面加载不成功」。
enum PddLink {
    /// 按平台分流：拼多多走 order.html，淘宝走交易详情页，京东还没接通就先打开首页。
    static func open(platform: Platform, orderNo: String) {
        switch platform {
        case .pdd:
            openDefault(orderNo: orderNo)
        case .tb:
            let sn = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
            let web = "https://buyertrade.taobao.com/trade/detail/trade_item_detail.htm?bizOrderId=\(sn)"
            if let url = URL(string: web) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        case .jd:
            if let url = URL(string: "openapp.jdmobile://") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }

    static func orderDetailURL(orderNo: String) -> URL? {
        let sn = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
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
