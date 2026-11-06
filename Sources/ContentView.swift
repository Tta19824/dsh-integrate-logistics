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
        .alert("提示", isPresented: $app.showToast) {
            Button("好", role: .cancel) {}
        } message: {
            Text(app.toast ?? "")
        }
    }
}

struct LoginSheet: View {
    let platform: Platform
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            WebView(url: platform.loginURL)
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
