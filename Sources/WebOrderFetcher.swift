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
        /// 渲染后的完整 HTML（PC 订单页是服务端渲染的，订单号只在这里）
        var html: String = ""
        /// 图片与时间戳的摘要（按纵向坐标排序），用来给文字解析出来的订单补图和时间
        var digest: String = "[]"
        /// 跟进的链接（「查看物流」点进去的那个地址），没跟进就是空
        var followedURL: String = ""
        var storeCookieNames: [String] = []
        var headerCookieNames: [String] = []
        /// 页面这次加载过的所有资源地址（performance timing），用来定位真正的接口
        var resources: String = "[]"
    }

    private var webView: WKWebView?
    /// 预热过的地址与时间：页面已加载好时，刷新可以直接省掉这一次导航
    private var warmURL: URL?
    private var warmAt: Date?
    /// 按用途复用 WebView：拼多多列表、淘宝列表各自一个，刷新时两个平台可以并行跑，
    /// 也不会互相把对方的页面顶掉。
    private var slots: [String: WKWebView] = [:]
    /// 最近一次把某个槽导航到新地址的时间：用于「刚打开过的页面直接复用」，
    /// 别为了一次手动刷新把整页重新加载一遍（那是京东一次刷新 3 秒里的大头）。
    private var loadedAt: [String: Date] = [:]

    /// 在页面里找 innerText 含指定文字、且**最短**的那个链接，返回它的 href。
    /// 订单卡片整体常常也被包在一个 <a> 里，取最短才能命中「查看物流」这种小链接。
    static func findLinkJS(text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (function(){
          var target = '\(escaped)';
          var best = '';
          var bestLen = 999;
          var list = document.querySelectorAll('a');
          for (var i = 0; i < list.length; i++) {
            var t = (list[i].innerText || '').trim();
            if (t.indexOf(target) < 0) continue;
            if (t.length > 24) continue;
            var href = list[i].href || '';
            if (!href) continue;
            if (href.indexOf('list_bought_items') >= 0) continue;
            if (t.length < bestLen) { bestLen = t.length; best = href; }
          }
          return best;
        })()
        """
    }

    /// 把页面和最长的可滚动容器都滚到底，返回当前正文字数
    static var scrollBottomJS: String {
        """
        (function(){
          var best = null, bestH = 0;
          var nodes = document.querySelectorAll('div,section,ul,main');
          for (var i = 0; i < nodes.length; i++) {
            var n = nodes[i];
            if (n.scrollHeight > n.clientHeight + 200 && n.clientHeight > 250) {
              if (n.scrollHeight > bestH) { bestH = n.scrollHeight; best = n; }
            }
          }
          if (best) { best.scrollTop = best.scrollHeight; }
          if (document.scrollingElement) { document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight; }
          window.scrollTo(0, document.body.scrollHeight);
          return String(document.body ? (document.body.innerText || '').length : 0);
        })()
        """
    }

    /// 这个页面加载过的所有资源地址：接口、脚本、图片都在这，用来反查真正的数据接口
    static var resourcesJS: String {
        """
        (function(){
          try {
            var out = [];
            var es = performance.getEntriesByType('resource') || [];
            for (var i = 0; i < es.length; i++) { out.push(es[i].name); }
            return JSON.stringify(out);
          } catch (e) { return '[]'; }
        })()
        """
    }

    /// 当前页面正文字数，用来判断懒加载有没有新内容进来
    static var probeJS: String {
        """
        (function(){ var t = document.body ? (document.body.innerText || '') : ''; return String(t.length); })()
        """
    }

    /// 默认只展示最新两条，点「展开更多物流明细」把剩下的拉出来（只点非链接元素，避免整页跳走）
    static var expandTraceJS: String {
        """
        (function(){
          var els = document.querySelectorAll('div,span,p,button');
          for (var i = 0; i < els.length; i++) {
            var t = (els[i].innerText || '').trim();
            if (t === '展开更多物流明细' || t === '展开更多') {
              try { els[i].click(); return '1'; } catch (e) {}
            }
          }
          return '0';
        })()
        """
    }

    private var hookScript: String {
        """
        (function(){
          if (window.__dshInstalled) return;
          window.__dshInstalled = true;
          window.__dshCap = [];
          function clip(s, n) {
            try { var t = String(s === undefined || s === null ? '' : s); return t.length > n ? t.slice(0, n) : t; }
            catch (e) { return ''; }
          }
          function hdr(h) {
            var o = {};
            try {
              if (!h) return o;
              if (typeof h.forEach === 'function') {
                h.forEach(function (v, k) { o[String(k)] = String(v); });
              } else if (Object.prototype.toString.call(h) === '[object Array]') {
                for (var i = 0; i < h.length; i++) {
                  var pair = h[i];
                  if (pair && pair.length === 2) o[String(pair[0])] = String(pair[1]);
                }
              } else {
                for (var k in h) { if (Object.prototype.hasOwnProperty.call(h, k)) o[String(k)] = String(h[k]); }
              }
            } catch (e) {}
            return o;
          }
          function push(u, t, r) {
            try {
              if (typeof t !== 'string' || t.length === 0 || t.length > 900000) return;
              // 400 字装不下带 body 的订单接口 URL（翻页要靠它改 page），留长一点
              var item = { u: String(u || '').slice(0, 8000), b: t };
              if (r) item.r = r;
              window.__dshCap.push(item);
            } catch (e) {}
          }
          var of = window.fetch;
          if (of) {
            window.fetch = function() {
              var args = arguments;
              var init = args[1] || {};
              var req = {
                u: clip(typeof args[0] === 'string' ? args[0] : ((args[0] && args[0].url) || ''), 30000),
                m: String(init.method || (args[0] && args[0].method) || 'GET').toUpperCase(),
                h: hdr(init.headers),
                d: clip(init.body, 30000)
              };
              return of.apply(this, args).then(function(r) {
                try { r.clone().text().then(function(t){ push(r.url || req.u, t, req); }); } catch (e) {}
                return r;
              });
            };
          }

          // 淘宝的 mtop 接口走 JSONP（<script src=...callback=mtopjsonp1>），fetch/XHR 钩子抓不到；
          // 所以在 script 插入 DOM 之前，先把它的回调名注册到 window 上，数据一到就存下来。
          var seen = {};
          function hookScript(node) {
            try {
              var src = node && node.src ? String(node.src) : (node && node.__dshSrc) || '';
              if (!src) return;
              var m = /[?&](?:callback|cb)=([^&]+)/.exec(src);
              if (!m) return;
              var name = decodeURIComponent(m[1]);
              if (!name || seen[name]) return;
              seen[name] = true;
              window[name] = function(d) { try { push(src, JSON.stringify(d)); } catch (e) {} return d; };
            } catch (e) {}
          }
          var ap = Node.prototype.appendChild;
          Node.prototype.appendChild = function(n) {
            try { if (n && n.tagName === 'SCRIPT') hookScript(n); } catch (e) {}
            return ap.apply(this, arguments);
          };
          try {
            var d = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
            if (d && d.set) {
              Object.defineProperty(HTMLScriptElement.prototype, 'src', {
                configurable: true,
                get: function() { return d.get.call(this); },
                set: function(v) {
                  try {
                    this.__dshSrc = v;
                    if (this.tagName === 'SCRIPT' && this.isConnected === false) hookScript(this);
                  } catch (e) {}
                  d.set.call(this, v);
                }
              });
            }
          } catch (e) {}

          var oo = XMLHttpRequest.prototype.open;
          var os = XMLHttpRequest.prototype.send;
          var oh = XMLHttpRequest.prototype.setRequestHeader;
          XMLHttpRequest.prototype.open = function(m, u) {
            this.__dshM = String(m || 'GET').toUpperCase();
            this.__dshUrl = u;
            this.__dshH = {};
            return oo.apply(this, arguments);
          };
          XMLHttpRequest.prototype.setRequestHeader = function(k, v) {
            try { if (!this.__dshH) this.__dshH = {}; this.__dshH[String(k)] = String(v); } catch (e) {}
            return oh.apply(this, arguments);
          };
          XMLHttpRequest.prototype.send = function(body) {
            var x = this;
            try {
              var req = { u: clip(x.__dshUrl, 30000), m: x.__dshM || 'GET', h: x.__dshH || {}, d: clip(body, 30000) };
              x.addEventListener('load', function(){ try { push(x.__dshUrl, x.responseText, req); } catch (e) {} });
            } catch (e) {}
            return os.apply(this, arguments);
          };
        })();
        """
    }

    /// 只取「图片地址 + 时间戳」两种信息，连同纵向坐标，用来按顺序对到订单卡片上。
    private static let digestJS = #"""
    (function(){
      var out = { imgs: [], times: [] };
      try {
        var im = document.images || [];
        for (var i = 0; i < im.length && out.imgs.length < 80; i++) {
          var s = im[i].currentSrc || im[i].src || "";
          if (/^\/\//.test(s)) s = "https:" + s;
          if (!/^https?:\/\//.test(s)) continue;
          var r = im[i].getBoundingClientRect();
          if (r.width < 40 || r.height < 40) continue;
          out.imgs.push({ s: s, y: Math.round(r.top + window.scrollY) });
        }
        var all = document.body ? document.body.getElementsByTagName("*") : [];
        for (var j = 0; j < all.length && out.times.length < 160; j++) {
          var el = all[j];
          if (el.children.length > 2) continue;
          var t = (el.textContent || "").replace(/\s+/g, " ").trim();
          if (t.length < 8 || t.length > 40) continue;
          var m = t.match(/\d{4}-\d{1,2}-\d{1,2}\s+\d{1,2}:\d{2}/);
          if (!m) continue;
          var rr = el.getBoundingClientRect();
          out.times.push({ t: m[0], y: Math.round(rr.top + window.scrollY) });
        }
      } catch (e) {}
      return JSON.stringify(out);
    })()
    """#

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
    func warmUp(url: URL, cookieHeader: String, platform: Platform = .pdd) async {
        let wv = slots["pdd"] ?? makeWebView(slot: "pdd")
        webView = wv
        await prefillCookies(cookieHeader, platform: platform, force: platform == .jd)
        var request = URLRequest(url: url)
        request.setValue(
            UserAgent.iOS,
            forHTTPHeaderField: "User-Agent"
        )
        _ = try? await wv.load(request)
        warmURL = url
        warmAt = Date()
    }

    /// 在已登录的页面里直接发一次请求（页面自己带 cookie，不需要我们把凭证搬来搬去）
    func inPageFetch(_ url: String) async -> String {
        guard let wv = slots["list-jd"] else { return "没有京东页面（跳过）" }
        let js = """
        var u = args.url;
        return fetch(u, { credentials: 'include' }).then(function (r) {
            return r.text().then(function (t) {
                return String(r.status) + '|' + String(t.length) + '|' + t.slice(0, 180);
            });
        }).catch(function (e) { return 'ERR ' + e.message; });
        """
        do {
            let v = try await wv.callAsyncJavaScript(js, arguments: ["url": url], in: nil, in: .page)
            return (v as? String) ?? ""
        } catch {
            return "ERR " + error.localizedDescription
        }
    }

    /// 在页面里发请求并拿回完整响应体（用来直取 JSON，不用等页面渲染）
    func inPageFetchJSON(_ url: String) async -> String {
        guard let wv = slots["list-jd"] else { return "ERR 没有京东页面" }
        let js = """
        var u = args.url;
        return fetch(u, { credentials: 'include' }).then(function (r) {
            return r.text().then(function (t) { return String(r.status) + '|' + t; });
        }).catch(function (e) { return 'ERR ' + e.message; });
        """
        do {
            let v = try await wv.callAsyncJavaScript(js, arguments: ["url": url], in: nil, in: .page)
            return (v as? String) ?? "ERR 空返回"
        } catch {
            return "ERR " + error.localizedDescription
        }
    }

    /// 在已经打开的页面里，把之前抓到的某条请求原样再发一次。
    /// 好处：cookie、UA、签名参数都由页面自己带，不用我们把凭证搬来搬去。
    /// 返回 "status|body"，没有可用页面或没有匹配请求时返回 nil。
    /// 在已打开的页面里重放候选请求，返回多份响应体（按当初响应大小从大到小，最多 3 份）。
    /// 用 "\n#####\n" 拼接，调用方自行拆分。
    func inPageReplayBodies(slot: String, urlContains: String) async -> (bodies: [String], note: String) {
        guard let wv = slots[slot] else { return ([], "NOPAGE") }
        guard wv.url != nil else { return ([], "NOURL") }
        let listJS = """
        (function () {
            var key = KEY;
            var caps = window.__dshCap || [];
            var out = [];
            for (var i = 0; i < caps.length; i++) {
                var e = caps[i] || {};
                var u = String(e.u || '');
                if (u.indexOf(key) < 0) continue;
                if (!e.r) continue;
                out.push({ i: i, n: String(e.b || '').length });
            }
            out.sort(function (a, b) { return b.n - a.n; });
            return JSON.stringify(out);
        })()
        """
        let listCode = listJS.replacingOccurrences(of: "KEY", with: "\u{0022}" + urlContains + "\u{0022}")
        guard let listRaw = try? await wv.evaluateJavaScript(listCode),
              let listStr = listRaw as? String,
              let listData = listStr.data(using: .utf8),
              let listArr = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]] else {
            return ([], "NOLIST")
        }
        if listArr.isEmpty { return ([], "NONE") }

        var bodies: [String] = []
        var lastNote = "SMALL"
        for item in listArr.prefix(3) {
            guard let idx = item["i"] as? Int else { continue }
            let kick = """
            window.__dshReplay = '';
            (function () {
                var caps = window.__dshCap || [];
                var e = caps[IDX] || {};
                var r = e.r || null;
                if (!r) { window.__dshReplay = 'NONE'; return; }
                var opt = { credentials: 'include', method: r.m || 'POST' };
                if (r.h) opt.headers = r.h;
                if (r.d) opt.body = r.d;
                fetch(String(e.u || ''), opt).then(function (resp) {
                    return resp.text().then(function (t) {
                        window.__dshReplay = String(resp.status) + '|' + t;
                    });
                }).catch(function (err) {
                    window.__dshReplay = 'ERR ' + err.message;
                });
            })();
            """
            let code = kick.replacingOccurrences(of: "IDX", with: String(idx))
            _ = try? await wv.evaluateJavaScript(code)
            var got = ""
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                let v = try? await wv.evaluateJavaScript("window.__dshReplay || ''")
                if let s = v as? String, !s.isEmpty { got = s; break }
            }
            if got.isEmpty { lastNote = "TIMEOUT"; continue }
            if got.hasPrefix("ERR") { return ([], got) }
            let parts = got.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "200" else { lastNote = "STATUS"; continue }
            let body = String(parts[1])
            if body.count < 4000 { lastNote = "SMALL"; continue }
            bodies.append(body)
        }
        return (bodies, bodies.isEmpty ? lastNote : "OK")
    }

    /// 保证 list-jd 这个槽里已经打开了京东页面（没有就打开并等加载完）
    /// 不再死等固定秒数：只要页面已经落到 jd.com 且 hook 装好，立刻返回（省掉 6 秒空等）。
    func ensureJdPage(cookieHeader: String, wait: Double = 6) async -> Bool {
        if let wv = slots["list-jd"], let host = wv.url?.host, host.contains("jd.com") { return true }
        let wv = slots["list-jd"] ?? makeWebView(slot: "list-jd")
        await prefillCookies(cookieHeader, platform: .jd, force: true)
        guard let url = URL(string: "https://my.m.jd.com/index.html?sceneval=2") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(UserAgent.iOS,
                         forHTTPHeaderField: "User-Agent")
        _ = await wv.load(request)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let alive = (try? await wv.evaluateJavaScript("(document.readyState && document.readyState !== 'loading') ? '1' : '0'")) as? String
            if alive == "1", let host = wv.url?.host, host.contains("jd.com") { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return wv.url?.host?.contains("jd.com") ?? false
    }

    /// 京东那个真正发出订单请求的页面（抓到的请求头里写的就是它：
    /// `x-referer-page: https://trade.m.jd.com/order/orderlist_jdm.shtml`）。
    /// 单独开一个槽：如果 my.m.jd.com 的页面被 CORS 挡住，就换这个同源页面重放。
    func ensureJdTradePage(cookieHeader: String, wait: Double = 7) async -> Bool {
        if let wv = slots["jd-replay"], let host = wv.url?.host, host.contains("trade.m.jd.com") { return true }
        let wv = slots["jd-replay"] ?? makeWebView(slot: "jd-replay")
        await prefillCookies(cookieHeader, platform: .jd, force: true)
        guard let url = URL(string: "https://trade.m.jd.com/order/orderlist_jdm.shtml") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(UserAgent.iOS,
                         forHTTPHeaderField: "User-Agent")
        _ = await wv.load(request)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let alive = (try? await wv.evaluateJavaScript("(document.readyState && document.readyState !== 'loading') ? '1' : '0'")) as? String
            if alive == "1", let host = wv.url?.host, host.contains("jd.com") { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return wv.url?.host?.contains("jd.com") ?? false
    }

    /// 直接把京东那条接口 URL 当网页打开：浏览器级的第一方请求，
    /// 没有 CORS 问题、不用跑页面 JS，响应体本身就是一份 JSON 文档，读 innerText 就行。
    /// 返回 "200|body" 或 "ERR 原因"。
    /// 注意：不补 Referer 时京东网关会回 `{"code":"1","echo":"cross-origin request…"}`（0.36.3 实测），
    /// 所以这里默认带上那条请求自己的 x-referer-page。
    func jdLoadJSONDirect(url: String, headers: [String: String], cookieHeader: String,
                          referer: String = "https://trade.m.jd.com/order/orderlist_jdm.shtml",
                          timeout: Double = 6) async -> String {
        guard let target = URL(string: url) else { return "ERR URL 拼错" }
        let wv = slots["jd-json"] ?? makeWebView(slot: "jd-json")
        await prefillCookies(cookieHeader, platform: .jd, force: true)
        var request = URLRequest(url: target)
        request.timeoutInterval = timeout
        request.setValue(UserAgent.iOS,
                         forHTTPHeaderField: "User-Agent")
        if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        for (k, v) in headers {
            if k.lowercased() == "referer" || k.lowercased() == "user-agent" { continue }
            request.setValue(v, forHTTPHeaderField: k)
        }
        _ = await wv.load(request)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = (try? await wv.evaluateJavaScript("String(document.readyState)")) as? String ?? ""
            if state == "complete" { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let text = (try? await wv.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
        if text.isEmpty { return "ERR 空文档" }
        return "200|" + text
    }

    /// 页面自取的结果：要么给一条抓包记录，要么说清楚为什么没拿到
    struct JdPagePick {
        var entry: String = ""      // 命中 orderList 的**最后**一条抓包记录（JSON）
        var entries: [String] = []  // 这次抓到的**所有**订单接口响应（分页/tab 各一次，最多 6 条）
        var reason: String = ""     // 失败原因
        var responses: Int = 0      // 这次页面一共抓到多少条接口响应
        var textHead: String = ""   // 页面正文开头
        var captured: String = ""   // 所有接口响应的概要（落盘用）
        var url: String = ""
        var reused: Bool = false    // 这次没重新加载页面，直接复用了热页面上已有的响应
    }

    /// 京东会话体检：只开一次「我的」页读正文，回答一个用户问不出来的问题 ——
    /// 「现在这份 cookie 京东还认不认」。绿点只代表有 cookie，不代表有效。
    func jdSessionProbe(cookieHeader: String) async -> String {
        let wv = slots["jd-probe"] ?? makeWebView(slot: "jd-probe")
        await prefillCookies(cookieHeader, platform: .jd, force: true)
        guard let url = URL(string: "https://my.m.jd.com/index.html?sceneval=2") else {
            return "体检失败：URL 拼错"
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(UserAgent.iOS, forHTTPHeaderField: "User-Agent")
        _ = await wv.load(request)
        let readJS = "(function(){var t=(document.body.innerText||'').replace(/\\s+/g,' ');return t.slice(0,300);})()"
        var text = ""
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let s = (try? await wv.evaluateJavaScript(readJS)) as? String, s.count > 20 {
                text = s
                break
            }
        }
        if text.contains("账号信息获取失败") {
            return "京东会话已失效（页面显示「账号信息获取失败」）→ 点「清空重登」"
        }
        if text.contains("请登录") || text.contains("免费注册") {
            return "京东会话已失效（页面显示「请登录」）→ 点「清空重登」"
        }
        if text.isEmpty {
            return "体检没结论：京东页面 5 秒内没渲染出文字（网络慢或被拦）"
        }
        return "京东会话有效：页面开头「\(String(text.prefix(40)))」"
    }

    /// 让京东页面自己去请求订单列表（不点 tab、不等渲染、不滚动），
    /// 只等 __dshCap 里出现带 orderList 的响应，然后把那一条整条交回来。
    ///
    /// 为什么需要它：存档里的 URL 放久了会变成空壳，而页面自己发的请求永远是新鲜的，
    /// 比等整页渲染（9–10 秒）便宜得多。
    func jdOrderListFromPage(cookieHeader: String, urlString: String,
                             clickText: String = "全部订单", wait: Double = 6,
                             deep: Bool = true, reuseWithin: Double = 45) async -> JdPagePick {
        var pick = JdPagePick()
        pick.url = urlString
        guard let target = URL(string: urlString) else {
            pick.reason = "URL 拼错"
            return pick
        }
        let wv = slots["list-jd"] ?? makeWebView(slot: "list-jd")
        await prefillCookies(cookieHeader, platform: .jd, force: true)
        let probe = "(function(){var a=window.__dshCap||[];for(var i=0;i<a.length;i++){if(String(a[i].b||'').indexOf('orderList')>=0)return '1';}return '0';})()"
        let countJS = "String((window.__dshCap||[]).length)"
        let take = #"""
        (function(){
          var a = window.__dshCap || [];
          var out = [];
          for (var i = 0; i < a.length; i++) {
            var b = String(a[i].b || '');
            if (b.indexOf('orderList') < 0) continue;
            var e = a[i] || {};
            out.push(JSON.stringify({ u: String(e.u || ''), r: e.r || null, b: b }));
          }
          if (out.length > 6) { out = out.slice(out.length - 6); }
          return JSON.stringify(out);
        })()
        """#
        // 刚打开过的订单页（reuseWithin 秒内）直接复用已抓到的响应：整页重新加载
        // 要等 SPA 自己把订单接口发出来，那 2 秒在「手点刷新」时纯属白花。
        let warmHost = wv.url?.host ?? ""
        if reuseWithin > 0, warmHost.contains("jd.com"),
           Date().timeIntervalSince(loadedAt["list-jd"] ?? .distantPast) < reuseWithin {
            let warm = await jdCapturedEntries(wv, js: take)
            if !warm.isEmpty {
                pick.entries = warm
                pick.entry = warm.last ?? ""
                pick.responses = warm.count
                pick.reused = true
                return pick
            }
        }
        var request = URLRequest(url: target)
        request.timeoutInterval = 20
        request.setValue(UserAgent.iOS,
                         forHTTPHeaderField: "User-Agent")
        _ = await wv.load(request)
        loadedAt["list-jd"] = Date()

        let started = Date()
        let deadline = started.addingTimeInterval(wait)
        var clicked = false
        var hitAt: Date? = nil
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if hitAt == nil, ((try? await wv.evaluateJavaScript(probe)) as? String) == "1" {
                hitAt = Date()
            }
            // 京东手机版一页 10 条，翻页/切 tab 会再发一条订单接口。
            // 命中后再多等 0.35 秒，把同时到达的响应一起收走（原来是 0.9 秒，纯等待）。
            if let h = hitAt, Date().timeIntervalSince(h) >= 0.35 { break }
            let n = Int((try? await wv.evaluateJavaScript(countJS)) as? String ?? "0") ?? 0
            pick.responses = n
            // 首屏没自己拉订单，就点一次「全部订单」，再继续等
            if !clicked, Date().timeIntervalSince(started) > 2.2 {
                clicked = true
                _ = try? await wv.evaluateJavaScript(clickTabJS([clickText]))
            }
            // 页面已经正常跑起来（接口一堆）却始终没有订单接口：多半是京东侧降级，别死等
            if Date().timeIntervalSince(started) > 4, n >= 8 { break }
        }
        if hitAt != nil {
            var entries = await jdCapturedEntries(wv, js: take)
            // 只有一条响应时，滚到底触发「加载更多」把第 2 页也收走 —— 只抓第一条正是
            // 「到货没取的订单刷不出来」的原因（一页 10 条，第 11 单就丢了）。
            if deep, entries.count <= 1 {
                _ = try? await wv.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let more = await jdCapturedEntries(wv, js: take)
                if more.count > entries.count { entries = more }
            }
            if !entries.isEmpty {
                pick.entries = entries
                pick.entry = entries.last ?? ""
                return pick
            }
        }
        // 把这次页面到底请求了什么全部记下来，供落盘排查
        let summaryJS = #"""
        (function(){
          var a = window.__dshCap || [];
          var items = [];
          for (var i = 0; i < a.length && i < 25; i++) {
            var b = String(a[i].b || '');
            var r = a[i].r || null;
            items.push({
              m: r ? String(r.m || '') : '',
              u: String(a[i].u || '').slice(0, 180),
              n: b.length,
              h: b.slice(0, 140).replace(/\s+/g, ' ')
            });
          }
          var text = document.body ? String(document.body.innerText || '') : '';
          return JSON.stringify({ n: a.length, text: text.slice(0, 400), items: items });
        })()
        """#
        if let raw = (try? await wv.evaluateJavaScript(summaryJS)) as? String, !raw.isEmpty {
            pick.captured = raw
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                pick.responses = (obj["n"] as? Int) ?? pick.responses
                pick.textHead = (obj["text"] as? String) ?? ""
            }
        }
        pick.reason = "页面没抓到订单接口（接口响应 \(pick.responses) 条）"
        return pick
    }

    /// 从页面里把当前所有「含 orderList 的响应」取成字符串数组（新→旧按抓包顺序）。
    private func jdCapturedEntries(_ wv: WKWebView, js: String) async -> [String] {
        let raw = (try? await wv.evaluateJavaScript(js)) as? String ?? ""
        guard let d = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
        return arr
    }

    /// 在指定槽的页面里把一条请求原样重发（方法 / 头 / 请求体都由调用方给），
    /// 返回 "status|body"，异常时返回 "NOPAGE" / "TIMEOUT" / "ERR 原因"。
    ///
    /// 为什么不用 callAsyncJavaScript：0.36.1 里那条路把 Promise 的返回值交回来永远是 `()`
    /// （JS 明明返回字符串，Swift 侧拿到 undefined），0.36.0 的 inPageFetch 也是同一个症状。
    /// 改用这里已经被拼多多验证过的写法：先 evaluateJavaScript 打开发请求（不取返回值），
    /// 再把结果写在 window.__dshReplay 上，Swift 每 120ms 轮询读一次。
    func inPageReplay(slot: String = "list-jd", url: String, method: String, headers: [String: String], body: String, timeoutMS: Double = 6000) async -> String {
        guard let wv = slots[slot], let host = wv.url?.host, !host.isEmpty else { return "NOPAGE" }
        let headersJSON: String = {
            guard let d = try? JSONSerialization.data(withJSONObject: headers, options: []),
                  let s = String(data: d, encoding: .utf8) else { return "{}" }
            return s
        }()
        let lines: [String] = [
            "window.__dshReplay = '';",
            "(function () {",
            "  var opt = { credentials: 'include', method: " + Self.jsString(method) + " };",
            "  var h = " + headersJSON + ";",
            "  if (h && Object.keys(h).length > 0) opt.headers = h;",
            "  var b = " + Self.jsString(body) + ";",
            "  if (b && b.length > 0) opt.body = b;",
            "  fetch(" + Self.jsString(url) + ", opt).then(function (r) {",
            "    return r.text().then(function (t) { window.__dshReplay = String(r.status) + '|' + t; });",
            "  }).catch(function (e) {",
            "    window.__dshReplay = 'ERR ' + ((e && e.message) ? String(e.message) : 'fetch failed');",
            "  });",
            "})();"
        ]
        _ = try? await wv.evaluateJavaScript(lines.joined(separator: "\n"))
        let tries = max(Int(timeoutMS / 120), 8)
        for _ in 0..<tries {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if let s = (try? await wv.evaluateJavaScript("window.__dshReplay || ''")) as? String, !s.isEmpty {
                return s
            }
        }
        return "TIMEOUT"
    }

    /// 把 Swift 字符串变成能安全塞进 JS 源码的字面量（含引号与换行）
    private static func jsString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let t = String(data: d, encoding: .utf8), t.count >= 2 else { return "\"\"" }
        return String(t.dropFirst().dropLast())
    }

    /// 把 list-jd 页面里抓到的、和京东订单接口相关的那几条请求列出来（诊断用）
    func jdCapturedRequests() async -> String {
        guard let wv = slots["list-jd"] else { return "NOPAGE" }
        let js = """
        (function () {
            var caps = window.__dshCap || [];
            var out = [];
            for (var i = 0; i < caps.length; i++) {
                var e = caps[i] || {};
                var u = String(e.u || '');
                var r = e.r || null;
                var ru = r ? String(r.u || '') : '';
                var combined = u + ' ' + ru;
                if (combined.indexOf('order_list') < 0 && String(e.b || '').indexOf('orderList') < 0) continue;
                out.push({
                    i: i,
                    m: r ? String(r.m || '') : 'NOR',
                    u: ru.length > 160 ? ru.slice(0, 160) : ru,
                    q: ru.length,
                    d: r ? String(r.d || '').length : 0,
                    b: String(e.b || '').length
                });
            }
            return JSON.stringify(out);
        })()
        """
        let raw = (try? await wv.evaluateJavaScript(js)) as? String ?? "ERR"
        return raw
    }

    func capture(platform: Platform = .pdd, urls: [URL], cookieHeader: String, seconds: Double = 22, clickTabs: Bool = true,
        clickTexts: [String] = [], minWait: Double = 0, strict: Bool = false, scroll: Bool = false, stopOnEntries: Bool = true, userAgent: String? = nil, expand: Bool = false, followLink: String? = nil, readyJS: String? = nil, slot: String = "main", referer: String? = nil, clickReadyJS: String? = nil) async throws -> Capture {
        let wv = slots[slot] ?? makeWebView(slot: slot)
        webView = wv
        await prefillCookies(cookieHeader, platform: platform, force: platform == .jd)

        let headerCookieNames = cookieHeader.split(separator: ";").compactMap { pair -> String? in
            let t = pair.split(separator: "=", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return t.isEmpty ? nil : t
        }
        var storeCookieNames: [String] = []
        if platform == .jd {
            let all = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
            }
            storeCookieNames = all.filter { $0.domain.contains("jd.com") || $0.domain.contains("360buy.com") }.map { $0.name }.sorted()
        }

        var tried: [String] = []
        var best: Capture?
        var followed = ""
        let startedAt = Date()

        for url in urls {
            var request = URLRequest(url: url)
            if let userAgent, !userAgent.isEmpty {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            } else if userAgent == nil {
                request.setValue(UserAgent.iOS, forHTTPHeaderField: "User-Agent")
            }
            if let referer, !referer.isEmpty {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }

            var loaded = true
            if warmURL == url, let at = warmAt, Date().timeIntervalSince(at) < 180 {
                // 预热页还在：直接进入刷新标签这一步，省掉一次完整导航
                loaded = true
            } else {
                _ = try? await wv.load(request)
                if let readyJS {
                    // 没有可等的接口响应、但渲染完就能判断"到齐了"的页面（淘宝物流页）：
                    // 每 300ms 问一次，条件成立立刻往下走，不用干等到超时。
                    loaded = false
                    for _ in 0..<70 {
                        let flag = (try? await wv.evaluateJavaScript(readyJS)) as? String ?? "0"
                        if flag == "1" { loaded = true; break }
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                } else {
                    loaded = await waitForData(wv: wv, seconds: seconds, strict: strict)
                }
                if scroll {
                    let rounds = readyJS == nil ? 3 : 1
                    for _ in 0..<rounds {
                        _ = try? await wv.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)")
                        try? await Task.sleep(nanoseconds: readyJS == nil ? 900_000_000 : 500_000_000)
                    }
                    if readyJS == nil {
                        _ = await waitForData(wv: wv, seconds: max(2, seconds * 0.35), strict: strict)
                    }
                }
                if minWait > 0 {
                    let cost = Date().timeIntervalSince(startedAt)
                    if cost < minWait { try? await Task.sleep(nanoseconds: UInt64((minWait - cost) * 1_000_000_000)) }
                }
            }
            warmURL = nil

            // 淘宝的物流明细默认只露两条，点一下「展开更多物流明细」把全部拉出来
            if expand {
                _ = try? await wv.evaluateJavaScript(Self.expandTraceJS)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }

            // 订单详情页只给一句物流摘要，真正的轨迹在「查看物流详情」那一页
            if let follow = followLink {
                let js = Self.findLinkJS(text: follow)
                if let href = (try? await wv.evaluateJavaScript(js)) as? String,
                   href.hasPrefix("http"), let next = URL(string: href) {
                    followed = href
                    _ = try? await wv.load(URLRequest(url: next))
                    // 物流页是懒加载：边滚边看字数，连续两次不涨就认为到底了（最多约 8 秒）
                    var stable = 0
                    var lastLen = 0
                    for i in 0..<14 {
                        try? await Task.sleep(nanoseconds: i == 0 ? 500_000_000 : 400_000_000)
                        let raw = (try? await wv.evaluateJavaScript(Self.scrollBottomJS)) as? String ?? "0"
                        let len = Int(raw) ?? 0
                        if len == lastLen { stable += 1 } else { stable = 0 }
                        lastLen = len
                        if len > 30000 && stable >= 2 { break }
                    }
                    _ = try? await wv.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)")
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    _ = try? await wv.evaluateJavaScript(Self.expandTraceJS)
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
            }

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

            if !clickTexts.isEmpty {
                for wanted in clickTexts {
                    _ = try? await wv.evaluateJavaScript(self.clickTabJS([wanted]))
                    if let clickReadyJS {
                        var ready = false
                        for _ in 0..<4 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            let flag = (try? await wv.evaluateJavaScript(clickReadyJS)) as? String ?? "0"
                            if flag == "1" { ready = true; break }
                        }
                        if !ready { try? await Task.sleep(nanoseconds: 800_000_000) }
                    } else {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                    }
                }
                title = (try? await wv.evaluateJavaScript("document.title || ''")) as? String ?? title
                text = (try? await wv.evaluateJavaScript("document.body ? (document.body.innerText || '') : ''")) as? String ?? text
            }

            let cards = (try? await wv.evaluateJavaScript(Self.cardsJS)) as? String ?? "[]"
            let payload = (try? await wv.evaluateJavaScript("JSON.stringify(window.__dshCap || [])")) as? String ?? "[]"
            let freshCookie = await CookieStore.currentHeader(for: platform) ?? ""
            var html = (try? await wv.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''")) as? String ?? ""
            if html.count > 1_500_000 { html = String(html.prefix(1_500_000)) }
            let digest = (try? await wv.evaluateJavaScript(Self.digestJS)) as? String ?? "[]"
            let resources = (try? await wv.evaluateJavaScript(Self.resourcesJS)) as? String ?? "[]"
            let made = Capture(
                finalURL: wv.url?.absoluteString ?? url.absoluteString,
                title: title,
                text: text,
                payloadJSON: payload,
                landedOnLogin: false,
                tried: tried,
                cookieHeader: freshCookie,
                cardsJSON: cards,
                html: html,
                digest: digest,
                followedURL: followed,
                storeCookieNames: storeCookieNames,
                headerCookieNames: headerCookieNames,
                resources: resources
            )
            if stopOnEntries && Self.payloadEntryCount(payload) == 0 {
                // 这个地址没抓到接口响应，继续试下一个地址
                if best == nil { best = made }
                continue
            }
            return made
        }

        if let best { return best }

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
        return try await capture(urls: [url], cookieHeader: cookieHeader, seconds: 14, clickTabs: false, slot: "detail-pdd")
    }

    /// 打开淘宝订单详情页，用来读快递公司、运单号和物流轨迹。
    func captureTaobaoDetail(orderNo: String, cookieHeader: String) async throws -> Capture {
        let encoded = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
        guard let url = URL(string: "https://buyertrade.taobao.com/trade/detail/trade_item_detail.htm?bizOrderId=\(encoded)") else {
            throw FetchError.badURL
        }
        return try await capture(platform: .tb, urls: [url], cookieHeader: cookieHeader, seconds: 9, clickTabs: false, strict: false, followLink: "查看物流", slot: "detail-tb")
    }

    /// 淘宝 PC 的物流详情页（服务端渲染完整轨迹），作为「查看物流」跟丢时的备选。
    func captureTaobaoWuliu(orderNo: String, cookieHeader: String) async throws -> Capture {
        let encoded = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
        guard let url = URL(string: "https://wuliu.taobao.com/user/order_detail_new.htm?trade_id=\(encoded)") else {
            throw FetchError.badURL
        }
        return try await capture(platform: .tb, urls: [url], cookieHeader: cookieHeader, seconds: 7, clickTabs: false, strict: false, scroll: false, expand: true)
    }

    /// 打开淘宝的物流轨迹页（和 App 里「查看物流」同一个页面），把接口响应抓回来。
    func captureTaobaoLogistics(orderNo: String, cookieHeader: String) async throws -> Capture {
        let encoded = orderNo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? orderNo
        guard let url = URL(string: "https://market.m.taobao.com/app/dinamic/pc-trade-logistics/home.html?orderId=\(encoded)&entrance=pc") else {
            throw FetchError.badURL
        }
        return try await capture(
            platform: .tb,
            urls: [url],
            cookieHeader: cookieHeader,
            seconds: 20,
            clickTabs: false,
            strict: false,
            scroll: true,
            readyJS: "(document.querySelectorAll('.pc-node-wrapper').length >= 3) ? '1' : '0'",
            slot: "detail-tb"
        )
    }

    /// 打开商品详情页，用来捞真实店铺名（订单接口里的店铺是品牌馆名）。
    func captureGoods(goodsID: String, cookieHeader: String) async throws -> Capture {
        guard let url = URL(string: "https://mobile.pinduoduo.com/goods.html?goods_id=\(goodsID)") else {
            throw FetchError.badURL
        }
        return try await capture(urls: [url], cookieHeader: cookieHeader, seconds: 12, clickTabs: false, slot: "detail-pdd")
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
    /// 拼多多刷新：先借页面现算的签名把**第一页**问一次，不行再点标签兜底。
    ///
    /// 五次踩坑都记在这里，别再走回去：
    /// 1. 只点「本来就选中」的标签不发请求 → 把旧响应当成了现状；
    /// 2. 整份 `__dshCap` 不能交给解析器（一整天累积，实测拼出 80/110 条）；
    /// 3. `reload()` 会恢复滚动位置 → 页面先发一条带 `offset` 游标的翻页请求，拿回 7 月那批旧单
    ///    （`payload_pdd(4)/(5)` 实证：`server_time` 新鲜、10 条全是 `2607xx`）；
    /// 4. 新开 WebView 也一样 —— 游标是页面自己持久化的，照样从旧游标往下翻；
    /// 5. 点标签能出数据（0.36.39 实测「现在能刷出来了」），但要点三次、等 6 秒，太慢。
    ///
    /// 所以 0.36.40 起：**拿页面刚才发的那条请求当模板，删掉 `offset`、`page` 归 1，在同源 fetch 里重发一次**
    /// （`anti_content` 是页面刚算的，能过；同源不会 CORS）。约 0.5 秒拿到第一页。
    /// 失败才退回 0.36.39 的「依次点标签」。
    func pddWarmRefetch(cookieHeader: String, wait: Double = 6) async -> (payload: String, text: String, reused: Bool)? {
        guard !cookieHeader.isEmpty else { return nil }
        guard let url = URL(string: "https://mobile.pinduoduo.com/order.html") else { return nil }
        let wv = slots["pdd"] ?? makeWebView(slot: "pdd")
        await prefillCookies(cookieHeader, platform: .pdd, force: false)

        let href = (try? await wv.evaluateJavaScript("String(location.href)")) as? String ?? ""
        let warm = href.contains("pinduoduo") && href.contains("order")
            && Date().timeIntervalSince(loadedAt["pdd"] ?? .distantPast) < 900
        if !warm {
            var req = URLRequest(url: url)
            req.setValue(UserAgent.iOS, forHTTPHeaderField: "User-Agent")
            _ = await wv.load(req)
            loadedAt["pdd"] = Date()
            // 等页面自己先打一次 order_list（哪怕它带 offset）—— 我们要的是它的 URL/头/签名当模板
            let coldDeadline = Date().addingTimeInterval(6)
            while Date() < coldDeadline {
                let hasEntry = (try? await wv.evaluateJavaScript("(function(){var a=window.__dshCap||[];for(var i=0;i<a.length;i++){var u=String((a[i]||{}).u||'');if(u.indexOf('order_list')>=0){return '1'}}return ''})()")) as? String == "1"
                if hasEntry { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        // ① 最快的一条路（约 0.5 秒）：借模板请求重发第一页
        if let hit = await pddFirstPageRefetch(wv, seconds: 4) {
            return (hit.payload, hit.text, warm)
        }

        // ② 退路：依次点三个标签，只要其中一次造成状态变化，页面就必须问一次服务端
        let baseline = await entryCount(wv)
        for name in ["待发货", "待收货", "全部"] {
            _ = try? await wv.evaluateJavaScript(clickTabJS([name]))
            try? await Task.sleep(nanoseconds: 260_000_000)
        }
        guard let hit = await warmNewestEntry(wv, baseline: baseline, seconds: wait) else { return nil }
        return (hit.payload, hit.text, warm)
    }

    /// 用页面自己刚发出的那条 `order_list` 当模板：删掉 `offset`、`page` 归 1，在页面里同源重发一次。
    /// 返回的 payload 是「一条抓包记录」的形状，交给 `PinduoduoParser` 和原来完全一致。
    private func pddFirstPageRefetch(_ wv: WKWebView, seconds: Double) async -> (payload: String, text: String)? {
        let kick = """
        (function(){var a=window.__dshCap||[];var e=null;for(var i=a.length-1;i>=0;i--){var x=a[i]||{};var u=String(x.u||'');if(u.indexOf('order_list')>=0&&String(x.b||'').length>200){e=x;break}}if(!e){return 'NO_ENTRY'}var body=String((e.r||{}).d||'');var bad=false;try{var j=JSON.parse(body);delete j.offset;j.page=1;body=JSON.stringify(j)}catch(err){bad=true}if(bad){return 'NO_BODY'}window.__dshFirstPage='';fetch(e.u,{method:String((e.r||{}).m||'POST'),headers:{'Content-Type':'application/json'},body:body,credentials:'include'}).then(function(r){return r.text()}).then(function(t){try{window.__dshFirstPage=JSON.stringify([{u:e.u,m:'POST',h:{},d:body,b:t}])}catch(err){window.__dshFirstPage='ERR'+err}}).catch(function(err){window.__dshFirstPage='ERR'+err});return 'SENT'})()
        """
        guard let kickRes = (try? await wv.evaluateJavaScript(kick)) as? String, kickRes == "SENT" else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let payload = (try? await wv.evaluateJavaScript("String(window.__dshFirstPage||'')")) as? String,
                  payload.count > 10 else { continue }
            if payload.hasPrefix("ERR") { return nil }
            guard payload.contains("\"orders\"") else { return nil }
            let bodyText = (try? await wv.evaluateJavaScript("document.body ? (document.body.innerText || '') : ''")) as? String ?? ""
            return (payload, bodyText)
        }
        return nil
    }

    /// 收「`baseline` 之后、请求体里没有 `offset`」的 order_list 响应；
    /// 一条都没有就退而收最新的一条，免得一次结果都不给。
    private func warmNewestEntry(_ wv: WKWebView, baseline: Int, seconds: Double) async -> (payload: String, text: String)? {
        func freshTopJS(requireTop: Bool) -> String {
            let skip = requireTop ? "if(off){continue}" : ""
            return """
            (function(){var a=window.__dshCap||[];var out=[];for(var i=\(baseline);i<a.length;i++){var e=a[i]||{};var u=String(e.u||'');var b=String(e.b||'');if(u.indexOf('order_list')<0||b.length<200){continue}var off='';try{var j=JSON.parse(String((e.r||{}).d||''));off=String(j.offset||'')}catch(x){};\(skip)out.push(e)}return JSON.stringify(out)})()
            """
        }
        func bodyText() async -> String {
            (try? await wv.evaluateJavaScript("document.body ? (document.body.innerText || '') : ''")) as? String ?? ""
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let payload = (try? await wv.evaluateJavaScript(freshTopJS(requireTop: true))) as? String,
               payload.count > 2, payload != "[]" {
                return (payload, await bodyText())
            }
        }
        if let payload = (try? await wv.evaluateJavaScript(freshTopJS(requireTop: false))) as? String,
           payload.count > 2, payload != "[]" {
            return (payload, await bodyText())
        }
        return nil
    }

    /// 响应里的 `server_time` 有多旧（秒）。认不出来就当「很旧」，宁可重载一次。
    private func serverTimeAge(_ payload: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: "\"server_time\"\\s*:\\s*(\\d{9,12})") else { return 9999 }
        let ns = payload as NSString
        guard let m = re.firstMatch(in: payload, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return 9999 }
        let v = Int(ns.substring(with: m.range(at: 1))) ?? 0
        guard v > 0 else { return 9999 }
        return max(0, Int(Date().timeIntervalSince1970) - v)
    }
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

    /// 京东电脑版详情页必须带 `PassKey`（32 位十六进制），而这个参数是页面「点订单详情」时
    /// 由站点自己拼出来的 —— 直接拼 `details.jd.com/normal/item.action?orderid=…` 会被弹回订单列表
    /// （0.36.20 实测：`finalURL` 直接落成 `order.jd.com/center/list.action`，所以取件码永远读不到）。
    /// 所以这条路只能：打开订单列表 → 找到这张卡里的「订单详情」→ 点它 → 等跳转 → 读正文。
    /// 返回 `200|<最终URL>|<正文>` 或 `ERR …`。
    /// 最近一次进到详情页时，页面上那张商品主图（京东列表页是懒加载，这里最稳）
    private(set) var lastDetailImage = ""

    func jdPCDetailByClick(orderNo: String, cookieHeader: String,
                           slot: String = "detail-jd-bg", wait: Double = 16) async -> String {
        lastDetailImage = ""
        guard let target = URL(string: "https://order.jd.com/center/list.action") else { return "ERR URL" }
        let wv: WKWebView
        if let exist = slots[slot], exist.url?.host?.contains("order.jd.com") == true {
            wv = exist
        } else {
            wv = makeWebView(slot: slot, desktop: true)
        }
        await prefillCookies(cookieHeader, platform: .jd, force: true)
        var request = URLRequest(url: target)
        request.timeoutInterval = wait
        request.setValue(UserAgent.macOS, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.jd.com/", forHTTPHeaderField: "Referer")
        _ = await wv.load(request)
        // 京东新版列表的「订单详情」是 target=_blank / window.open 打开的。
        // WKWebView 没实现 createWebViewWith，这两条路都等于「点了没反应」——
        // 先把 window.open 和 _blank 改成同标签跳转，再点。
        _ = try? await wv.evaluateJavaScript(Self.jdOpenHijackJS)

        let started = Date()
        var clicked = false
        var triedLink = false
        var triedPassKey = false
        var lastHref = ""
        var lastText = ""
        while Date().timeIntervalSince(started) < wait {
            try? await Task.sleep(nanoseconds: 400_000_000)
            lastHref = (try? await wv.evaluateJavaScript("String(location.href)")) as? String ?? lastHref
            let text = (try? await wv.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
            if text.count > lastText.count { lastText = text }
            if lastHref.contains("details.jd.com") {
                // 详情页是服务端渲染，但物流块可能晚一拍才出来
                var best = lastText
                for _ in 0..<12 {
                    if best.contains("取件码") || best.contains("运单号") { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let later = (try? await wv.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
                    if later.count > best.count { best = later }
                }
                lastDetailImage = (try? await wv.evaluateJavaScript(Self.jdDetailImageJS)) as? String ?? ""
                return "200|\(lastHref)|\(best)"
            }
            // 有时页面把详情链接（带 PassKey）直接渲染在 DOM 里，只是没被点到。
            // 先扫一遍外链，命中就直接打开 —— 这条最省事也最稳。
            if !triedPassKey, Date().timeIntervalSince(started) > 1.6 {
                triedPassKey = true
                if let raw = (try? await wv.evaluateJavaScript(Self.jdPassKeyScanJS)) as? String,
                   let data = raw.data(using: .utf8),
                   let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] {
                    let hit = arr.first { ($0["no"] ?? "") == orderNo } ?? (arr.count == 1 ? arr[0] : nil)
                    if let u = hit?["url"], let detailURL = URL(string: u) {
                        OrderClient.JdPCLinks.save([orderNo: u])
                        var req2 = URLRequest(url: detailURL)
                        req2.setValue(UserAgent.macOS, forHTTPHeaderField: "User-Agent")
                        req2.setValue("https://order.jd.com/center/list.action", forHTTPHeaderField: "Referer")
                        _ = await wv.load(req2)
                    }
                }
            }
            if !clicked {
                let ok = (try? await wv.evaluateJavaScript(Self.jdDetailClickJS(orderNo: orderNo))) as? String ?? "0"
                clicked = ok == "1"
            }
            // 点不动再退一步：直接把这张卡的详情链接拿去同标签打开
            if !triedLink, Date().timeIntervalSince(started) > 4 {
                triedLink = true
                _ = try? await wv.evaluateJavaScript(Self.jdDetailLinkJS(orderNo: orderNo))
            }
        }
        return "ERR 没跳进详情页（正文 \(lastText.count) 字，当前 \(lastHref)）"
    }

    /// 详情页上的商品主图：取第一张 360buyimg 且宽度够大的，跳过图标/logo/占位。
    private static let jdDetailImageJS = #"""
    (function(){
      var imgs = document.querySelectorAll('img');
      var best = '', bestW = 0;
      for (var i = 0; i < imgs.length; i++) {
        var im = imgs[i];
        var s = im.currentSrc || im.getAttribute('data-lazy-img') || im.getAttribute('data-src') || im.getAttribute('src') || '';
        if (!s || s.indexOf('360buyimg.com') < 0) continue;
        var l = s.toLowerCase();
        if (l.indexOf('icon') >= 0 || l.indexOf('logo') >= 0 || l.indexOf('blank') >= 0 || l.indexOf('sprite') >= 0) continue;
        var w = im.naturalWidth || im.width || 0;
        if (w < 60) continue;
        if (w > bestW) { bestW = w; best = s; }
      }
      return best;
    })()
    """#
    /// 在渲染后的 DOM 里找「带 PassKey 的详情链接」。
    /// 详情页的 PassKey 是列表页 JS 生成的，只存在于渲染后的 DOM 里，不在 HTTP 返回的 HTML 里。
    private static let jdPassKeyScanJS = #"""
    (function(){
      var html = document.documentElement ? document.documentElement.outerHTML : '';
      var out = [];
      var re = /details\.jd\.com\/normal\/item\.action\?orderid=(\d{8,25})[^"'\s<>]*/gi;
      var m;
      while ((m = re.exec(html)) !== null && out.length < 6) {
        var u = m[0];
        if (u.toLowerCase().indexOf('passkey=') < 0) continue;
        if (u.indexOf('http') !== 0) { u = 'https://' + u; }
        out.push({ no: m[1], url: u });
      }
      return JSON.stringify(out);
    })()
    """#
    /// 把 window.open / target=_blank 改成同标签跳转，否则 WKWebView 里点了没反应。
    private static let jdOpenHijackJS = #"""
    (function(){
      try {
        window.open = function(u){ if (u) { location.href = u; } return null; };
      } catch (e) {}
      try {
        document.addEventListener('click', function(ev){
          var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
          if (a && (a.target === '_blank' || a.target === '_new')) {
            ev.preventDefault();
            location.href = a.href;
          }
        }, true);
      } catch (e) {}
      return '1';
    })()
    """#

    /// 兜底：这张卡的详情链接要是就在 DOM 里，直接跳过去。
    private static func jdDetailLinkJS(orderNo: String) -> String {
        """
        (function(){
          var no = '\(orderNo)';
          var as = document.querySelectorAll('a[href]');
          for (var i = 0; i < as.length; i++) {
            var a = as[i];
            var h = a.getAttribute('href') || '';
            if (h.indexOf('orderid') < 0 && h.indexOf('orderId') < 0 &&
                h.indexOf('viewOrder') < 0 && h.indexOf('orderDetail') < 0 &&
                h.indexOf('details.jd.com') < 0) continue;
            var p = a, hit = false;
            for (var up = 0; up < 9 && p; up++) {
              p = p.parentElement;
              if (!p) break;
              if ((p.innerText || '').indexOf(no) >= 0) { hit = true; break; }
            }
            if (hit) { location.href = a.href; return '1'; }
          }
          return '0';
        })()
        """
    }
    /// 在订单列表里点开「这张卡」的订单详情：只点祖先节点正文里带这个订单号的那个，
    /// 因为「订单详情」既是表头列名也是行内按钮，点表头什么都不会发生。
    private static func jdDetailClickJS(orderNo: String) -> String {
        """
        (function(){
          var no = '\(orderNo)';
          var all = document.querySelectorAll('a,button,span,div');
          var best = null;
          for (var i = 0; i < all.length; i++) {
            var e = all[i];
            if ((e.innerText || '').trim() !== '订单详情') continue;
            var p = e, hit = false;
            for (var up = 0; up < 9 && p; up++) {
              p = p.parentElement;
              if (!p) break;
              if ((p.innerText || '').indexOf(no) >= 0) { hit = true; break; }
            }
            if (hit) best = e;
          }
          if (best) { best.click(); return '1'; }
          return '0';
        })()
        """
    }
    private func prefillCookies(_ header: String, platform: Platform = .pdd, force: Bool = false) async {
        guard !header.isEmpty else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let existing = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        var existingNames = Set(existing.map { $0.name })
        let pairs = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let domains: [String]
        switch platform {
        case .pdd: domains = [".pinduoduo.com", ".yangkeduo.com"]
        case .tb: domains = [".taobao.com", ".tmall.com"]
        case .jd: domains = [".jd.com", ".360buy.com"]
        }
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if force {
                // force 就是「以这份为准」：先删掉 WebView 里同名的旧 cookie，
                // 否则残留的死会话（比如上一次登录留下的 thor）会盖住刚存进来的新凭证 ——
                // 0.36.15 实测过：京东电脑版明明扫码登上了，渲染出来的页面还是「你好，请登录」。
                for stale in existing where stale.name == name {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        store.delete(stale) { cont.resume() }
                    }
                }
            } else if existingNames.contains(name) {
                continue
            }
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

    private static func payloadEntryCount(_ payloadJSON: String) -> Int {
        guard let data = payloadJSON.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return list.count
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

    private func makeWebView(slot: String = "main", desktop: Bool = false) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.addUserScript(
            WKUserScript(source: hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: desktop ? 1180 : 390,
                                         height: desktop ? 900 : 820), configuration: cfg)
        // 隐藏抓包槽也必须用登录时那套 UA，否则「登录」和「抓单」在京东眼里是两台设备
        UserAgent.apply(to: wv, desktop: desktop)
        wv.alpha = 0.02
        wv.isUserInteractionEnabled = false
        // 京东新版订单页的「订单详情」是 window.open/_blank 开的。WKWebView 不实现
        // createWebViewWith 就等于点了没反应 —— 交给本类实现，原地打开。
        wv.uiDelegate = self
        attach(wv)
        slots[slot] = wv
        return wv
    }

    /// 电脑版订单页（`order.jd.com/center/list.action`）渲染一遍，把正文交回来。
    /// 这条路用的是桌面会话（thor/pin），和手机版 pt_key 无关 —— 手机版被风控时它可能还活着。
    /// 返回 "200|正文" 或 "ERR 原因"。
    func jdPCListRender(cookieHeader: String,
                        urlString: String = "https://order.jd.com/center/list.action?d=1",
                        wait: Double = 7) async -> String {
        guard let target = URL(string: urlString) else { return "ERR URL 拼错" }
        let wv: WKWebView
        if let exist = slots["jd-pc"], exist.url?.host?.contains("order.jd.com") == true {
            wv = exist
        } else {
            wv = makeWebView(slot: "jd-pc", desktop: true)
        }
        await prefillCookies(cookieHeader, platform: .jd, force: true)
        var request = URLRequest(url: target)
        request.timeoutInterval = wait
        request.setValue(UserAgent.macOS, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.jd.com/", forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        _ = await wv.load(request)

        let deadline = Date().addingTimeInterval(wait)
        var state = ""
        while Date() < deadline {
            state = (try? await wv.evaluateJavaScript("String(document.readyState)")) as? String ?? ""
            if state == "complete" { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // 列表是 JS 渲染的，complete 之后还要给一点时间出 DOM
        try? await Task.sleep(nanoseconds: 900_000_000)
        // 正文 + 商品图一起取。电脑版没有解析出图片 URL 的话，订单卡片就是空白 ——
        // 0.36.12 用户看到「京东的订单图片不见了」就是这么来的（电脑版顶替了带图的手机版）。
        let js = """
        (function(){
          var e = document.querySelector('#orderList, .order-list, #order-list') || document.body;
          var text = e ? e.innerText : '';
          var imgs = [];
          try {
            var nodes = (e || document).querySelectorAll('img');
            for (var i = 0; i < nodes.length; i++) {
              var s = nodes[i].getAttribute('data-lazy-img') || nodes[i].getAttribute('data-src')
                   || nodes[i].getAttribute('data-origin') || nodes[i].currentSrc || nodes[i].src || '';
              if (s.indexOf('360buyimg.com') >= 0 && s.indexOf('icon') < 0 && s.indexOf('logo') < 0 && s.indexOf('sprite') < 0 && (nodes[i].naturalWidth === 0 || nodes[i].naturalWidth >= 60)) {
                imgs.push(s);
              }
              if (imgs.length > 60) break;
            }
          } catch (err) {}
          // 每条订单的「订单详情」链接也一起带回去：详情页 URL 带签名/时间戳，自己拼不出来，
          // 只能从列表页的 <a href> 里捡。物流详情/取件码就靠它。
          var links = {};
          try {
            var as = (e || document).querySelectorAll('a[href]');
            for (var j = 0; j < as.length; j++) {
              var h = as[j].href || '';
              var m = h.match(/(?:orderId|orderid|deal_id)=(\\d{6,25})/);
              if (m) links[m[1]] = h;
              if (j > 400) break;
            }
          } catch (err2) {}
          // 图片必须跟订单号绑在一起。0.36.19 是从「订单详情链接」往上爬找卡片，
          // 但电脑版列表里的详情按钮不带 href（是 JS 点击），所以一张也没绑上，
          // 界面就一直拿平铺数组的第一张 —— 页头那个 1544 字节的小图标。
          // 反过来做：遍历图片，往上找那个正文里带「订单号 X」的卡片，对上了就绑。
          var pics = {};
          try {
            var imgs2 = (e || document).querySelectorAll('img');
            for (var k = 0; k < imgs2.length; k++) {
              var im = imgs2[k];
              var cand = im.getAttribute('data-lazy-img') || im.getAttribute('data-src')
                      || im.getAttribute('data-origin') || im.currentSrc || im.src || '';
              if (!cand) continue;
              if (cand.indexOf('360buyimg.com') < 0) continue;
              if (cand.indexOf('blank') >= 0 || cand.indexOf('loading') >= 0 || cand.indexOf('default') >= 0) continue;
              if (cand.indexOf('icon') >= 0 || cand.indexOf('logo') >= 0 || cand.indexOf('sprite') >= 0) continue;
              if (im.naturalWidth > 0 && im.naturalWidth < 60) continue;
              var p2 = im;
              for (var up2 = 0; up2 < 9 && p2; up2++) {
                p2 = p2.parentElement;
                if (!p2) break;
                var mb = (p2.innerText || '').match(/订单号[^0-9]{0,8}(\\d{9,25})/);
                if (mb) {
                  if (!pics[mb[1]]) pics[mb[1]] = cand;
                  break;
                }
              }
            }
          } catch (err3) {}
          // 老版详情页（details.jd.com/normal/item.action?orderid=…&PassKey=…）才是信息齐全的那一页，
          // 取件码 / 运单号 / 轨迹时间线都在里面。PassKey 只能从这类链接里捡。
          var details = {};
          try {
            var as3 = (e || document).querySelectorAll('a[href]');
            for (var q = 0; q < as3.length; q++) {
              var h3 = as3[q].href || '';
              if (h3.indexOf('details.jd.com') < 0 && h3.indexOf('item.action') < 0) continue;
              var m3 = h3.match(/(?:orderid|orderId)=(\\d{6,25})/);
              if (m3) details[m3[1]] = h3;
              if (q > 400) break;
            }
          } catch (err4) {}
          return JSON.stringify({ t: text, i: imgs, l: links, p: pics, d: details });
        })()
        """
        let payload = (try? await wv.evaluateJavaScript(js)) as? String ?? ""
        if payload.isEmpty { return "ERR 空文档（state=\(state)）" }
        if let data = payload.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = obj["t"] as? String, !text.isEmpty {
            return "200|" + payload
        }
        return "ERR 取不到正文（state=\(state)）"
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

// MARK: - 京东新窗口

extension WebOrderFetcher: WKUIDelegate {
    /// `window.open` / `target=_blank`：WKWebView 不实现这个回调就什么都不发生。
    /// 这里直接把目标地址塞回同一个 webview，等于「在新标签打开」变成「原地跳转」。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            var req = URLRequest(url: url)
            req.setValue(UserAgent.macOS, forHTTPHeaderField: "User-Agent")
            req.setValue("https://order.jd.com/center/list.action", forHTTPHeaderField: "Referer")
            webView.load(req)
        }
        return nil
    }
}