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
        /// 订单列表卡片上的文字（含取件码、最新物流），JSON 数组 [{sn,text}]
        var cardsJSON: String = "[]"
    }

    private var webView: WKWebView?
    /// 预热过的地址与时间：页面已加载好时，刷新可以直接省掉这一次导航
    private var warmURL: URL?
    private var warmAt: Date?
    /// 复用同一个 WebView：省掉每次刷新重建 + 重新握手的时间
    private var reusableWebView: WKWebView?

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
      t: (document.body ? document.body.innerText.length : 0),
      o: (window.__dshCap || []).some(function(e){ return String(e.u || '').indexOf('order_list') >= 0; })
    })
    """

    /// 抓订单列表卡片：每张卡片里有订单号链接、取件码、最新一条物流。
    static let cardsJS = """
    (function(){
      try {
        var out = [], seen = {};
        function snFrom(s){
          var m = /([0-9]{6}-[0-9]{9,})/.exec(s || '');
          return m ? m[1] : '';
        }
        function add(sn, text){
          if (!sn || seen[sn] || !text) return;
          seen[sn] = 1;
          out.push({ sn: sn, text: text.length > 600 ? text.slice(0, 600) : text });
        }
        var links = document.querySelectorAll('a[href*="order_sn="]');
        for (var i = 0; i < links.length; i++) {
          var a = links[i];
          var m = /order_sn=([A-Za-z0-9-]+)/.exec(a.href || '');
          if (!m) continue;
          var p = a, best = '';
          for (var k = 0; k < 5 && p; k++) {
            p = p.parentElement;
            if (!p) break;
            var t = p.innerText || '';
            if (t.length > 800) break;
            if (t.length > 30) best = t;
          }
          add(m[1], best);
        }
        var blocks = document.querySelectorAll('div,section,li');
        for (var j = 0; j < blocks.length; j++) {
          var el = blocks[j];
          var tx = el.innerText || '';
          if (tx.length < 10 || tx.length > 600) continue;
          if (!/取件码|提货码|取货码|顺丰|中通|圆通|韵达|申通|极兔|邮政|EMS|德邦/.test(tx)) continue;
          add(snFrom(tx), tx);
        }
        return JSON.stringify(out);
      } catch (e) { return '[]'; }
    })()
    """

    /// 启动预热：App 一打开就把订单页加载好，用户点刷新时页面已经是热页。
    func warmUp(url: URL, cookieHeader: String) async {
        let wv = reusableWebView ?? makeWebView()
        webView = wv
        await prefillCookies(cookieHeader)
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        _ = try? await wv.load(request)
        warmURL = url
        warmAt = Date()
    }

    /// 依次尝试多个地址，遇到登录页就换下一个；拿到数据就停。
    func capture(platform: Platform = .pdd, urls: [URL], cookieHeader: String, seconds: Double = 22, clickTabs: Bool = true, minWait: Double = 0, strict: Bool = false, scroll: Bool = false) async throws -> Capture {
        let wv = reusableWebView ?? makeWebView()
        webView = wv
        await prefillCookies(cookieHeader)

        var tried: [String] = []
        let startedAt = Date()

        for url in urls {
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )

            var loaded = true
            if warmURL == url, let at = warmAt, Date().timeIntervalSince(at) < 180 {
                // 预热页还在：直接进入刷新标签这一步，省掉一次完整导航
                loaded = true
            } else {
                _ = try? await wv.load(request)
                loaded = await waitForData(wv: wv, seconds: seconds, strict: strict)
                if scroll {
                    for _ in 0..<3 {
                        _ = try? await wv.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)")
                        try? await Task.sleep(nanoseconds: 900_000_000)
                    }
                    _ = await waitForData(wv: wv, seconds: max(2, seconds * 0.35), strict: strict)
                }
                if minWait > 0 {
                    let cost = Date().timeIntervalSince(startedAt)
                    if cost < minWait { try? await Task.sleep(nanoseconds: UInt64((minWait - cost) * 1_000_000_000)) }
                }
            }
            warmURL = nil

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
                // 只关心「待发货 / 待收货」两个标签：点一下让页面去请求对应列表。
                // 不再死等固定秒数，盯住新到的 order_list 响应，来了立刻走。
                var baseline = await self.entryCount(wv)
                _ = try? await wv.evaluateJavaScript(self.clickTabJS(["待发货", "打包中"]))
                _ = await self.waitForNewOrderList(wv: wv, from: baseline, seconds: 2.6)
                baseline = await self.entryCount(wv)
                _ = try? await wv.evaluateJavaScript(self.clickTabJS(["待收货"]))
                _ = await self.waitForNewOrderList(wv: wv, from: baseline, seconds: 3.0)
            }

            let cards = (try? await wv.evaluateJavaScript(Self.cardsJS)) as? String ?? "[]"
            let payload = (try? await wv.evaluateJavaScript("JSON.stringify(window.__dshCap || [])")) as? String ?? "[]"
            let freshCookie = await CookieStore.currentHeader(for: platform) ?? ""
            return Capture(
                finalURL: wv.url?.absoluteString ?? url.absoluteString,
                title: title,
                text: text,
                payloadJSON: payload,
                landedOnLogin: false,
                tried: tried,
                cookieHeader: freshCookie,
                cardsJSON: cards
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

    private func waitForData(wv: WKWebView, seconds: Double, strict: Bool = false) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var first = true
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: first ? 500_000_000 : 500_000_000)
            first = false
            guard let raw = (try? await wv.evaluateJavaScript(statsJS)) as? String,
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let bytes = (obj["s"] as? Int) ?? 0
            let chars = (obj["t"] as? Int) ?? 0
            let hasList = (obj["o"] as? Bool) ?? false
            if hasList && bytes > 5_000 { return true }
            if strict {
                // 淘宝/京东首屏有大量静态文字，不能用「文字够多」当完成信号，只认接口响应
                if bytes > 8_000 { return true }
            } else if bytes > 20_000 || chars > 400 {
                return true
            }
        }
        return false
    }

    private func entryCount(_ wv: WKWebView) async -> Int {
        guard let raw = (try? await wv.evaluateJavaScript("String((window.__dshCap || []).length)")) as? String else { return 0 }
        return Int(raw) ?? 0
    }

    /// 等新到的 order_list 响应；来了立刻返回，省掉原来的固定等待。
    private func waitForNewOrderList(wv: WKWebView, from: Int, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        let js = "(function(s){var a=window.__dshCap||[];for(var i=(s||0);i<a.length;i++){if(String(a[i].u||'').indexOf('order_list')>=0)return '1';}return '0';})"
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let v = (try? await wv.evaluateJavaScript(js + "(\\(from))")) as? String, v == "1" { return true }
        }
        return false
    }

    private func makeWebView() -> WKWebView {
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
        reusableWebView = wv
        return wv
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
