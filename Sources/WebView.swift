import SwiftUI
import UIKit
import WebKit

struct WebView: UIViewRepresentable {
    let url: URL
    var desktop: Bool = false
    /// 打开前先清掉这些域名下的 cookie（登录页要干净的环境才会给扫码）
    var clearDomains: [String] = []
    /// 自动点「扫码登录」那个标签页
    var autoQR: Bool = false
    var onFinish: ((WKNavigation?) -> Void)?

    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static let qrTabScript = """
    (function(){
      var tries = 0;
      function isQR(t){
        t = (t || '').trim();
        return t === '扫码登录' || t === '扫一扫登录' || t === '扫码';
      }
      function byText(){
        var els = document.querySelectorAll('div,span,a,button,li,p');
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          if (el.children.length > 2) continue;
          if (isQR(el.textContent)) { try { el.click(); } catch (e) {} return true; }
        }
        return false;
      }
      function byClass(){
        var el = document.querySelector('[class*="qr"],[id*="qr"],[class*="Qr"],[class*="QR"]');
        if (!el) return false;
        try { el.click(); } catch (e) { return false; }
        return true;
      }
      function tick(){
        tries++;
        var direct = document.querySelector('.qrcode-login');
        if (direct) { try { direct.click(); } catch (e) {} return true; }
        if (byText()) return true;
        if (tries > 6 && byClass()) return true;
        return false;
      }
      var id = setInterval(function(){
        if (tick() || tries > 25) clearInterval(id);
      }, 400);
    })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        if autoQR {
            config.userContentController.addUserScript(
                WKUserScript(source: Self.qrTabScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = desktop ? Self.desktopUA : nil

        if clearDomains.isEmpty {
            webView.load(URLRequest(url: url))
        } else {
            let store = WKWebsiteDataStore.default()
            store.httpCookieStore.getAllCookies { cookies in
                let group = DispatchGroup()
                for cookie in cookies where clearDomains.contains(where: { cookie.domain.contains($0) }) {
                    group.enter()
                    store.httpCookieStore.delete(cookie) { group.leave() }
                }
                group.notify(queue: .main) {
                    webView.load(URLRequest(url: url))
                }
            }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFinish: ((WKNavigation?) -> Void)?

        init(onFinish: ((WKNavigation?) -> Void)?) {
            self.onFinish = onFinish
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NSLog("[web] finished: \(webView.url?.absoluteString ?? "-")")
            onFinish?(navigation)
        }

        /// 页面里跳 `pinduoduo://` 之类的自定义 scheme：直接取消，**不**交给系统打开。
        /// 交给系统的话会被踹到拼多多 App 里愣在首页，登录页反而没了。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               !["http", "https", "about", "data", "javascript", "file", "blob"].contains(scheme) {
                NSLog("[web] blocked external scheme \(scheme)")
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[web] failed: \(error.localizedDescription)")
        }
    }
}
