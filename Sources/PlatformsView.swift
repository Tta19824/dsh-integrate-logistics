import SwiftUI
import UIKit

struct PlatformsView: View {
    @EnvironmentObject private var app: AppState

    private var capture: CaptureInfo { OrderClient.lastCapture }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Platform.allCases) { platform in
                        PlatformRow(platform: platform)
                    }
                } header: {
                    Text("平台账号")
                } footer: {
                    Text("登录后会打开该平台的网页，完成登录后点右上角「完成」，App 会把登录凭证存进钥匙串。")
                }

                Section {
                    ForEach(Platform.allCases) { platform in
                        let files = OrderClient.debugFiles(for: platform)
                        ForEach(files) { file in
                            if FileManager.default.fileExists(atPath: file.url.path) {
                                ShareLink(item: file.url) {
                                    HStack {
                                        Text(file.label)
                                        Spacer()
                                        Text(Self.fileSizeText(file.url))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                HStack {
                                    Text(file.label)
                                    Spacer()
                                    Text("未生成").foregroundStyle(.secondary)
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
                    Text("点有大小的一行即可分享出去（微信 → 文件传输助手）。")
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
    @EnvironmentObject private var app: AppState

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
            }

            HStack(spacing: 10) {
                Button(loggedIn ? "重新登录" : "登录") {
                    app.loginPlatform = platform
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("刷新订单") {
                    app.refresh(platform)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(app.busy != nil)

                Spacer()
            }

            if let time = app.loginTime(platform) {
                Text("登录于 \(time.formatted(date: .numeric, time: .shortened))，凭证 \(app.cookieSize(platform)) 字节")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
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
