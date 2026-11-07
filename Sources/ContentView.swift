import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppState()

    var body: some View {
        TabView {
            OrdersView()
                .tabItem { Label("订单", systemImage: "shippingbox") }

            PlatformsView()
                .tabItem { Label("平台", systemImage: "person.crop.circle") }
        }
        .environmentObject(app)
        .sheet(item: $app.loginPlatform) { platform in
            LoginSheet(platform: platform)
                .environmentObject(app)
        }
        .overlay(alignment: .top) {
            if let message = app.toast {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .onTapGesture { app.toast = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: app.toast)
    }
}

struct LoginSheet: View {
    let platform: Platform
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            WebView(
                url: platform.loginURL,
                clearDomains: platform == .pdd ? ["pinduoduo.com", "yangkeduo.com"] : [],
                autoQR: platform == .pdd
            )
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("\(platform.name) 登录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            app.finishLogin(platform)
                            dismiss()
                        }
                        .bold()
                    }
                }
        }
    }
}
