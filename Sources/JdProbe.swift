import SwiftUI
import WebKit

/// 京东订单页探测：把候选地址逐个打开，实时显示「落点 / 标题 / 订单号命中数」，
/// 用来确定哪一个地址才是真正的订单列表页。
struct JdProbeSheet: View {
    let startURL: String
    let label: String

    @Environment(\.dismiss) private var dismiss
    @State private var liveURL = "—"
    @State private var pageTitle = "—"
    @State private var hits = 0
    @State private var chars = 0
    @State private var web: WKWebView?
    @State private var desktop = false

    private var parsedURL: URL {
        URL(string: startURL) ?? URL(string: "https://m.jd.com")!
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("落点 \(URL(string: liveURL)?.host ?? "—")")
                            .font(.footnote.bold())
                        Spacer()
                        Text("订单号 ×\(hits)").font(.footnote.bold())
                            .foregroundStyle(hits > 0 ? .green : .secondary)
                    }
                    Text(liveURL).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    Text("标题「\(pageTitle)」· 正文 \(chars) 字")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))

                WebView(url: parsedURL, desktop: desktop, onReady: { v in web = v })
                    .id(desktop)
            }
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(desktop ? "手机版" : "电脑版") {
                        web = nil
                        desktop.toggle()
                    }
                }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                sample()
            }
        }
    }

    private func sample() {
        guard let web else { return }
        liveURL = web.url?.absoluteString ?? liveURL
        web.evaluateJavaScript("document.title") { value, _ in
            if let s = value as? String, !s.isEmpty { pageTitle = s }
        }
        web.evaluateJavaScript("(document.body.innerText || '').length") { value, _ in
            if let n = value as? NSNumber { chars = n.intValue }
        }
        web.evaluateJavaScript("((document.body.innerText || '').match(/订单号/g) || []).length") { value, _ in
            if let n = value as? NSNumber { hits = n.intValue }
        }
    }
}
