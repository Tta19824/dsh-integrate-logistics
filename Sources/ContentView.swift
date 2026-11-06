import SwiftUI
import WebKit

struct Platform: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

enum Platforms {
    static let all: [Platform] = [
        Platform(id: "pdd", name: "拼多多", url: URL(string: "https://mobile.pinduoduo.com/")!),
        Platform(id: "tb", name: "淘宝", url: URL(string: "https://main.m.taobao.com/mytaobao/index.html")!),
        Platform(id: "jd", name: "京东", url: URL(string: "https://m.jd.com/")!)
    ]
}

struct ContentView: View {
    @State private var selected: Platform = Platforms.all[0]
    @State private var cookieReport: String = ""
    @State private var showCookieReport: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Platforms.all) { platform in
                    Button(platform.name) {
                        selected = platform
                    }
                    .buttonStyle(.bordered)
                    .tint(selected == platform ? .accentColor : .gray)
                }

                Button("查 Cookie") {
                    inspectCookies()
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))

            Divider()

            WebView(url: selected.url)
                .id(selected.id)

            Divider()

            Text("冒烟测试 v0.1.0（1）· 只验证安装、运行、WebView 与 Cookie 读取")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color(.systemGroupedBackground))
        }
        .alert("Cookie 检查", isPresented: $showCookieReport) {
            Button("好", role: .cancel) {}
        } message: {
            Text(cookieReport)
        }
    }

    /// 只是验证“App 能不能读到 WebView 里的 cookie”——真正的软件完全依赖这个能力。
    private func inspectCookies() {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let platforms = ["pinduoduo", "taobao", "jd.com", "pdd"]
            let hits = cookies.filter { cookie in
                platforms.contains { cookie.domain.contains($0) }
            }
            let names = Array(Set(hits.map { $0.name })).sorted()
            let total = cookies.count

            DispatchQueue.main.async {
                if names.isEmpty {
                    cookieReport = "共 \(total) 个 cookie，其中平台相关 0 个。\n\n这是正常的——你还没登录。登录之后再点一次，应该能看到 PDDAccessToken / cookie2 这类名字。"
                } else {
                    cookieReport = "共 \(total) 个 cookie，平台相关 \(names.count) 个：\n\n" + names.joined(separator: "\n")
                }
                showCookieReport = true
            }
        }
    }
}
