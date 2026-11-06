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

                Section("调试") {
                    ForEach(Platform.allCases) { platform in
                        if FileManager.default.fileExists(atPath: OrderClient.latestRawFile(for: platform).path) {
                            ShareLink(item: OrderClient.latestRawFile(for: platform)) {
                                Label("分享 \(platform.name) 最近一次的原始页面", systemImage: "doc.text")
                                    .font(.footnote)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        OrderStore.shared.deleteAll()
                        app.reload()
                    } label: {
                        Text("清空本地订单")
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
                .disabled(!loggedIn || app.busy != nil)

                Spacer()
            }

            if let time = app.loginTime(platform) {
                Text("登录于 \(time.formatted(date: .numeric, time: .shortened))")
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
