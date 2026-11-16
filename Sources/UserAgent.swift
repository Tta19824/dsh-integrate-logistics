import Foundation
import WebKit

/// 全 App 只维护一套 UA。
///
/// 起因（2026-11-16 京东风控排查）：登录页跑的是 WKWebView 默认 UA（没有 `Version/… Safari/…`，
/// 一眼能看出是 App 内嵌浏览器），而抓单请求用的是写死 `iPhone OS 17_0` 的假 Safari UA。
/// 同一份 `pt_key` 以两种「设备身份」出现，京东风控很容易把它当成「会话被复制到另一台设备」，
/// 于是弹滑块 + 短信、把会话降级成「大促异常火爆」。所以这里统一成一份真机 Safari UA：
/// 登录 WebView、所有隐藏抓包槽、所有 URLSession 请求都用同一个字符串。
enum UserAgent {
    /// 真机系统版本，例如 "18.2"、"17.6"（不再写死 17.0）
    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// iOS UA 里的系统版本写法是下划线：`iPhone OS 18_2`
    static var systemVersionUnderscored: String {
        systemVersion.replacingOccurrences(of: ".", with: "_")
    }

    /// 手机版 Safari。关键是同时带 `Version/x` 和 `Safari/604.1` 两个标记，且版本与真机一致。
    static var iOS: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS \(systemVersionUnderscored) like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/\(systemVersion) Mobile/15E148 Safari/604.1"
    }

    /// 桌面版 Safari。只有确实要电脑版页面（淘宝 buyertrade、京东 order.jd.com）时才用。
    static var macOS: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/\(systemVersion) Safari/605.1.15"
    }

    /// 给 WKWebView 设上同一套身份。登录页和隐藏抓包槽都必须调用，
    /// 否则「登录时」和「抓单时」又是两种设备。
    static func apply(to webView: WKWebView, desktop: Bool = false) {
        webView.customUserAgent = desktop ? macOS : iOS
    }
}
