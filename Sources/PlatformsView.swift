import SwiftUI

struct PlatformsView: View {
    @EnvironmentObject private var app: AppState

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
                        if files.isEmpty {
                            HStack {
                                Text("\(platform.name) 抓取文件")
                                Spacer()
                                Text("未生成").foregroundStyle(.secondary)
                            }
                        } else {
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
                    Text("点任意一行即可把文件分享出去（微信 → 文件传输助手）。「接口数据」最有用，解析不准时把它发我。")
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
