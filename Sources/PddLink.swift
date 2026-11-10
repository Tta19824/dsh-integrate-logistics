import Foundation
import UIKit

/// 拼多多 App 深链：实测只有「网页同路径」这条能准确落到该订单的详情页，
/// 其余 order_detail / orders.html / open_url 都会停在「页面加载不成功」。
enum PddLink {
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
