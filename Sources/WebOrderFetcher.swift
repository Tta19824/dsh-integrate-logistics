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

    func capture(url: URL, wait seconds: Double = 14) async throws -> Capture {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.addUserScript(
            WKUserScript(source: hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 820), configuration: cfg)
        wv.alpha = 0.02
        wv.isUserInteractionEnabled = false
        attach(wv)
        webView = wv
        defer { detach() }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        _ = try await wv.load(request)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        let title = (try? await wv.evaluateJavaScript("document.title || ''")) as? String ?? ""
        let text = (try? await wv.evaluateJavaScript("document.body ? (document.body.innerText || '') : ''")) as? String ?? ""
        let payload = (try? await wv.evaluateJavaScript("JSON.stringify(window.__dshCap || [])")) as? String ?? "[]"

        return Capture(
            finalURL: wv.url?.absoluteString ?? url.absoluteString,
            title: title,
            text: text,
            payloadJSON: payload
        )
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
