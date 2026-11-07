import Foundation
import UIKit
import WebKit

/// 用真 WebView 打开订单页，让平台自己的 JS 去拉数据，我们把
/// ① 渲染后的 innerText ② 所有 fetch/XHR 响应体 抓回来。
/// 这样绕开 anti_content / mtop 签名这些没法在原生里复现的东西。
@MainActor
final class WebOrderFetcher: NSObject {
    static let shared = WebOrderFetcher()

    struct Capture {
        var finalURL: String
        var title: String
        var text: String
        var payloadJSON: String
        var landedOnLogin = false
        var tried: [String] = []
        /// 抓完之后 WebView 里的最新 cookie（平台会轮换 token，要回写）
        var cookieHeader: String = ""
    }

    private var webView: WKWebView?

    private var hookScript: String {
        """
        (function(){
          if (window.__dshInstalled) return;
          window.__dshInstalled = true;
          window.__dshCap = [];
          function push(u, t) {
            try {
              if (typeof t !== 'string' || t.length === 0 || t.length > 900000) return;
              window.__dshCap.push({ u: String(u || '').slice(0, 400), b: t });
            } catch (e) {}
          }
          var of = window.fetch;
          if (of) {
            window.fetch = function() {
              var args = arguments;
              return of.apply(this, args).then(function(r) {
                try { r.clone().text().then(function(t){ push(r.url || (args[0] && args[0].url) || '', t); }); } catch (e) {}
                return r;
              });
            };
          }
          var oo = XMLHttpRequest.prototype.open;
          var os = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(m, u) { this.__dshUrl = u; return oo.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function() {
            var x = this;
            try {
              x.addEventListener('load', function(){ try { push(x.__dshUrl, x.responseText); } catch (e) {} });
            } catch (e) {}
            return os.apply(this, arguments);
          };
        })();
        """
    }

    private let statsJS = """
    JSON.stringify({
      n: (window.__dshCap || []).length,
      s: (window.__dshCap || []).reduce(function(a, c){ return a + (c.b ? c.b.length : 0); }, 0),
      t: (document.body ? document.body.innerText.length : 0)
    })
    """

    /// 依次尝试多个地址，遇到登录页就换下一个；拿到数据就停。
    func capture(urls: [URL], cookieHeader: String, seconds: Double = 22, clickTabs: Bool = true) async throws -> Capture {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.addUserScript(
            WKUserScript(source: hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        await prefillCookies(cookieHeader)

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 820), configuration: cfg)
        wv.alpha = 0.02
        wv.isUserInteractionEnabled = false
        attach(wv)
        webView = wv
        defer { detach() }

        var tried: [String] = []

        for url in urls {
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )

            _ = try? await wv.load(request)
            let loaded = await waitForData(wv: wv, seconds: seconds)

            var title = (try? await wv.evaluateJavaScript("document.title || ''")) as? String ?? ""
            var text = (try? await wv.evaluateJavaScript("document.body ? (document.body.innerText || '') : ''")) as? String ?? ""
            tried.append("\(shortURL(url)) → \(title.isEmpty ? "无标题" : title)")

            // 落到登录页：说明这个地址要求重新验证，换下一个
            if isLoginPage(title: title, text: text) {
                continue
            }

            // 首屏没数据，同址再等一轮（不再重载，避免触发风控）
            if !loaded && text.count < 200 {
                _ = await waitForData(wv: wv, seconds: seconds * 0.7)
                title = (try? await wv.evaluateJavaScript("document.title || ''")) as? String ?? title
                text = (try? await wv.evaluateJavaScript("document.body ? (document.body.innerText || '') : ''")) as? String ?? text
                if isLoginPage(title: title, text: text) { continue }
            }

            if clickTabs {
                // 只关心「待发货 / 待收货」两个标签：点一下让页面去请求对应列表，
                // 抓到的多个 order_list_v4 响应会在解析时合并。
                _ = try? await wv.evaluateJavaScript(self.clickTabJS(["待发货", "打包中"]))
                await self.sleep(2.2)
                _ = try? await wv.evaluateJavaScript(self.clickTabJS(["待收货"]))
                await self.sleep(2.8)
            }

            let payload = (try? await wv.evaluateJavaScript("JSON.stringify(window.__dshCap || [])")) as? String ?? "[]"
            let freshCookie = await CookieStore.currentHeader(for: .pdd) ?? ""
            return Capture(
                finalURL: wv.url?.absoluteString ?? url.absoluteString,
                title: title,
                text: text,
                payloadJSON: payload,
                landedOnLogin: false,
                tried: tried,
                cookieHeader: freshCookie
            )
        }

        // 全都落到登录页
        let title = (try? await wv.evaluateJavaScript("document.title || ''")) as? String ?? ""
        let text = (try? await wv.evaluateJavaScript("document.body ? (document.body.innerText || '') : ''")) as? String ?? ""
        return Capture(
            finalURL: wv.url?.absoluteString ?? "",
            title: title,
            text: text,
            payloadJSON: "[]",
            landedOnLogin: true,
            tried: tried
        )
    }

    /// 打开单个订单的详情页，用来读物流轨迹和取件码。
    func captureDetail(orderNo: String, cookieHeader: String) async throws -> Capture {
        let encoded = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
        guard let url = URL(string: "https://mobile.pinduoduo.com/order.html?order_sn=\(encoded)") else {
            throw FetchError.badURL
        }
        return try await capture(urls: [url], cookieHeader: cookieHeader, seconds: 14, clickTabs: false)
    }

    /// 打开商品详情页，用来捞真实店铺名（订单接口里的店铺是品牌馆名）。
    func captureGoods(goodsID: String, cookieHeader: String) async throws -> Capture {
        guard let url = URL(string: "https://mobile.pinduoduo.com/goods.html?goods_id=\(goodsID)") else {
            throw FetchError.badURL
        }
        return try await capture(urls: [url], cookieHeader: cookieHeader, seconds: 12, clickTabs: false)
    }

    private func isLoginPage(title: String, text: String) -> Bool {
        if title == "登录" { return true }
        let marks = ["发送验证码", "请输入手机号", "密码登录", "请先登录", "扫码登录", "同意服务协议与隐私政策"]
        let hits = marks.filter { text.contains($0) }.count
        return hits >= 2
    }

    /// 把钥匙串里存的 cookie 灌回 WebView，避免 WebView 自己的存储被系统清过。
    /// 注意：WebView 里已经有的同名 cookie 不覆盖——那里的可能比钥匙串里的新。
    /// 在页面里找到文字完全等于某个标签名的元素并点它。
    private func clickTabJS(_ names: [String]) -> String {
        let list = names.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        (function(){
          var names = [\(list)];
          var els = document.querySelectorAll('div,span,a,li,p');
          for (var i = 0; i < els.length; i++) {
            var t = (els[i].innerText || '').trim();
            if (t.length === 0 || t.length > 8) { continue; }
            for (var j = 0; j < names.length; j++) {
              if (t === names[j]) { try { els[i].click(); return names[j]; } catch (e) {} }
            }
          }
          return '';
        })();
        """
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func prefillCookies(_ header: String) async {
        guard !header.isEmpty else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let existing = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        var existingNames = Set(existing.map { $0.name })
        let pairs = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let domains = [".pinduoduo.com", ".yangkeduo.com"]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !existingNames.contains(name) else { continue }
            for domain in domains {
                let props: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: domain,
                    .path: "/",
                ]
                guard let cookie = HTTPCookie(properties: props) else { continue }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    store.setCookie(cookie) { cont.resume() }
                }
            }
            existingNames.insert(name)
        }
    }

    private func waitForData(wv: WKWebView, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let raw = (try? await wv.evaluateJavaScript(statsJS)) as? String,
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let bytes = (obj["s"] as? Int) ?? 0
            let chars = (obj["t"] as? Int) ?? 0
            if bytes > 30_000 || chars > 600 { return true }
        }
        return false
    }

    private func shortURL(_ url: URL) -> String {
        let p = url.path.isEmpty ? "/" : url.path
        return "\(url.host ?? "")\(p)"
    }

    private func attach(_ wv: WKWebView) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return }
        wv.translatesAutoresizingMaskIntoConstraints = false
        win.addSubview(wv)
        win.sendSubviewToBack(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: win.leadingAnchor),
            wv.topAnchor.constraint(equalTo: win.topAnchor),
            wv.widthAnchor.constraint(equalToConstant: 390),
            wv.heightAnchor.constraint(equalToConstant: 820),
        ])
    }

    private func detach() {
        webView?.removeFromSuperview()
        webView = nil
    }
}
