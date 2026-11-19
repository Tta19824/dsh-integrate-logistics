import SwiftUI
import UIKit

struct PlatformsView: View {
    @EnvironmentObject private var app: AppState

    @State private var jdProbe: String?
    @State private var jdProbeLabel = ""
    /// 给用户手动过验证用的网页（京东风控时会要求滑一下）
    @State private var webPlatform: Platform?

    private var capture: CaptureInfo { OrderClient.lastCapture }

    /// 京东手机版可能的订单列表页，逐个试，看哪个真出「订单号」。
    static let jdPages: [(name: String, url: String)] = [
                ("order.m.jd.com/orderList/1?sceneval=2", "https://order.m.jd.com/orderList/1?sceneval=2"),
        ("wq.jd.com/order/orderlist", "https://wq.jd.com/order/orderlist?sceneval=2"),
        ("home.m.jd.com/myOrders.action", "https://home.m.jd.com/myOrders/myOrders.action"),
        ("m.jd.com/order/orderList.action", "https://m.jd.com/order/orderList.action"),
        ("order.jd.com/center/list.action", "https://order.jd.com/center/list.action"),
        ("my.m.jd.com 首页（已知落点）", "https://my.m.jd.com/index.html?sceneval=2")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Platform.allCases) { platform in
                        PlatformRow(platform: platform) { p in
                            webPlatform = p
                        }
                    }
                } header: {
                    Text("平台账号")
                } footer: {
                    Text("登录后会打开该平台的网页，完成登录后点右上角「完成」，App 会把登录凭证存进钥匙串。")
                }

                Section {
                    ForEach(Platform.allCases) { platform in
                        let files = OrderClient.debugFiles(for: platform)
                        if !files.isEmpty {
                            Text(platform.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(files) { file in
                                ShareLink(item: file.url) {
                                    HStack {
                                        Text(file.label)
                                        Spacer()
                                        Text(Self.fileSizeText(file.url))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }


                    Button(role: .destructive) {
                        OrderStore.shared.deleteAll()
                        app.reload()
                        app.show("已清空本地订单")
                    } label: {
                        Text("清空本地订单")
                    }
                } header: {
                    Text("调试 · 抓取文件")
                } footer: {
                    Text("只列已经生成的。点一行分享一个文件，微信一次只能发一个。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.traceInfo)
                        if !app.enrichInfo.isEmpty {
                            Text(app.enrichInfo).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                } header: {
                    Text("调试 · 轨迹库")
                } footer: {
                    Text("刷新后这行会变。如果显示「轨迹库 0 行」，说明轨迹根本没写进数据库。")
                }

                Section {
                    Text(PddFast.statusText())
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("清除直连存档") {
                        PddFast.clear()
                        app.toast = "已清除，下次刷新会重新抓一份"
                    }
                    .font(.caption)
                } header: {
                    Text("调试 · 拼多多直连")
                } footer: {
                    Text("有存档时刷新会直接重放请求，不开网页；显示「无存档」说明还没存下来。")
                }

                Section {
                    ForEach(Array(Self.jdPages.enumerated()), id: \.offset) { pair in
                        Button {
                            jdProbe = pair.element.url
                            jdProbeLabel = "\(pair.offset + 1). \(pair.element.name)"
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(pair.offset + 1). \(pair.element.name)")
                                Text(pair.element.url)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("调试 · 京东订单页")
                } footer: {
                    Text("挨个点开，看哪一页顶部显示「订单号 ×N」大于 0 —— 那就是真正的订单列表页，把编号告诉我。")
                }

                if let jd = app.orders.first(where: { $0.platform == .jd }) {
                    Section {
                        ForEach(Array(PddLink.jdCandidates(orderNo: jd.orderNo).enumerated()), id: \.offset) { pair in
                            Button {
                                if let url = URL(string: pair.element.url) {
                                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pair.element.name)
                                    Text(pair.element.url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        Text("调试 · 京东跳转")
                    } footer: {
                        Text("挨个点，看哪个能进京东 App 的订单详情页（不是首页、不是全部订单）；告诉我是第几个，我就把它设成默认。")
                    }
                }

                if let tb = app.orders.first(where: { $0.platform == .tb }) {
                    Section {
                        ForEach(Array(PddLink.tbCandidates(orderNo: tb.orderNo, itemID: tb.goodsID).enumerated()), id: \.offset) { pair in
                            Button {
                                if let url = URL(string: pair.element.url) {
                                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pair.element.name)
                                    Text(pair.element.url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        Text("调试 · 淘宝跳转")
                    } footer: {
                        Text("挨个点，看哪个能进淘宝 App 的订单页；告诉我是第几个，我就把它设成默认。")
                    }
                }

                Section {
                    if !capture.pageTitle.isEmpty {
                        HStack {
                            Text("页面标题")
                            Spacer()
                            Text(capture.pageTitle).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    HStack {
                        Text("接口响应条数")
                        Spacer()
                        Text("\(capture.entryCount)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("页面文本 / 接口字数")
                        Spacer()
                        Text("\(capture.textChars) / \(capture.payloadChars)").foregroundStyle(.secondary)
                    }
                    ForEach(capture.attempts, id: \.self) { row in
                        Text(row)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(capture.entrySizes, id: \.self) { row in
                        Text(row)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if !capture.snippet.isEmpty {
                        Text(capture.snippet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Button("复制最大一条响应（前 6000 字）") {
                        UIPasteboard.general.string = String(capture.largestBody.prefix(6000))
                        app.show("已复制 \(min(capture.largestBody.count, 6000)) 字到剪贴板，去微信粘贴")
                    }
                    .disabled(capture.largestBody.isEmpty)

                    if !capture.writeError.isEmpty {
                        Text("写入错误：\(capture.writeError)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("抓包摘要")
                } footer: {
                    Text("文件显示「未生成」时，先点「复制最大一条响应」，把文字粘贴到微信发我。")
                }

                if !capture.uaProbe.isEmpty {
                    Section {
                        ForEach(capture.uaProbe, id: \.self) { row in
                            Text(row).font(.caption2)
                        }
                    } header: {
                        Text("换 UA 直接请求的结果")
                    } footer: {
                        Text("这里「订单号 ×N」大于 0 的那种 UA，说明服务端会直接给数据，就不用绕 WebView 了。")
                    }
                }

                Section("最近一次结果") {
                    if let message = app.lastMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message)
                                .font(.footnote)
                            if let at = app.lastMessageAt {
                                Text(at.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        Text("还没有操作过").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("版本") {
                    HStack {
                        Text("版本号")
                        Spacer()
                        Text(AppInfo.version).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("平台")
            .sheet(isPresented: Binding(
                get: { jdProbe != nil },
                set: { if !$0 { jdProbe = nil } }
            )) {
                if let url = jdProbe {
                    JdProbeSheet(startURL: url, label: jdProbeLabel)
                }
            }
            .sheet(item: $webPlatform) { p in
                WebPageSheet(platform: p)
            }
        }
    }

    static func fileSizeText(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1048576) }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) B"
    }
}

struct PlatformRow: View {
    let platform: Platform
    var onOpenWeb: (Platform) -> Void = { _ in }
    @EnvironmentObject private var app: AppState
    @State private var confirmClear = false

    private var loggedIn: Bool { app.isLoggedIn(platform) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(platform.name)
                    .font(.body.weight(.medium))

                Circle()
                    .fill(loggedIn ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 7, height: 7)

                Text(loggedIn ? "已登录" : "未登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if app.busy == platform {
                    ProgressView().scaleEffect(0.8)
                }

                Toggle("", isOn: Binding(
                    get: { !app.isDisabled(platform) },
                    set: { app.setDisabled(platform, !$0) }
                ))
                .labelsHidden()
                .scaleEffect(0.8)
            }

            HStack(spacing: 10) {
                Button(platform == .jd
                       ? (app.hasPcLogin(platform) ? "电脑版重登" : "电脑版登录")
                       : (loggedIn ? "重新登录" : "登录")) {
                    if platform == .jd {
                        app.pcLoginPlatform = .jd
                    } else {
                        app.loginPlatform = platform
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("开网页") {
                    onOpenWeb(platform)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("刷新订单") {
                    app.refresh(platform)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(app.busy != nil)

                if platform == .jd {
                    Button("清空重登") { confirmClear = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                }

                Spacer()
            }

            if let time = app.loginTime(platform) {
                Text("登录于 \(time.formatted(date: .numeric, time: .shortened))，凭证 \(app.cookieSize(platform)) 字节")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if platform == .jd {
                if app.hasPcLogin(platform), let pcTime = app.pcLoginTime(platform) {
                    Text("电脑版凭证 存于 \(pcTime.formatted(date: .numeric, time: .shortened))（\(app.pcCookieSize(platform)) 字节）")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if app.pcCookieSize(platform) > 0 {
                    Text("电脑版凭证不完整（缺 thor/pin），点「电脑版登录」重登一次")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if app.jdBlocked {
                    Text("⚠️ 上次刷新被京东风控挡了 —— 绿点只代表有 cookie，不代表会话有效")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("清空京东电脑版的登录态？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清掉，重新扫码登录", role: .destructive) { app.clearPcLogin(.jd) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删掉电脑版（thor/pin）凭证。适用于「电脑版曾经登过、但订单页显示请登录」。")
        }
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// 手动打开平台网页：京东风控要求滑动验证时，用户在这里滑完再回来刷新。
struct WebPageSheet: View {
    let platform: Platform
    @Environment(\.dismiss) private var dismiss

    private var url: URL {
        if let custom = Platform.manualWebURL(platform), let u = URL(string: custom) { return u }
        return platform.loginURL
    }

    var body: some View {
        NavigationStack {
            WebView(url: url, desktop: platform == .pdd || platform == .jd)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(platform.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}
