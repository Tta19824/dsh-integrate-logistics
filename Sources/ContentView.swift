import SwiftUI
import UIKit
import WebKit
import Photos
import Combine

final class WebHandle: ObservableObject {
    weak var view: WKWebView?
}

struct ContentView: View {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            OrdersView()
                .tabItem { Label("订单", systemImage: "shippingbox") }

            PlatformsView()
                .tabItem { Label("平台", systemImage: "person.crop.circle") }
        }
        .environmentObject(app)
        .task {
            OrderClient.warmUp()
            // 首屏直接用库里的数据，后台默默补一次新的
            app.autoRefreshIfStale()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { app.autoRefreshIfStale(minutes: 5) }
        }
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
    @StateObject private var handle = WebHandle()
    @State private var autoClosed = false

    var body: some View {
        NavigationStack {
            WebView(
                url: platform.loginURL,
                desktop: platform == .pdd,
                clearDomains: platform == .pdd ? ["pinduoduo.com", "yangkeduo.com"] : [],
                autoQR: platform == .pdd,
                onReady: { handle.view = $0 }
            )
                .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
                    detectLogin()
                }
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
                    if platform == .pdd {
                        ToolbarItem(placement: .bottomBar) {
                            Button {
                                saveQRAndScan()
                            } label: {
                                Label("保存二维码并打开扫一扫", systemImage: "qrcode.viewfinder")
                            }
                        }
                    }
                }
        }
    }

    // MARK: - 自动发现登录成功

    private func detectLogin() {
        guard !autoClosed else { return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let names = Set(cookies.map { $0.name })
            let hit = platform.essentialCookies.allSatisfy { names.contains($0) }
            guard hit else { return }
            DispatchQueue.main.async {
                guard !autoClosed else { return }
                autoClosed = true
                app.finishLogin(platform)
                app.toast = "\(platform.name)：登录成功，凭证已自动保存"
                dismiss()
            }
        }
    }

    // MARK: - 保存二维码 + 跳到拼多多扫一扫

    private func saveQRAndScan() {
        guard let wv = handle.view else {
            app.toast = "页面还没加载好"
            return
        }
        let js = """
        (function(){
          var best = null, bestArea = 0;
          var list = document.querySelectorAll('img, canvas');
          for (var i = 0; i < list.length; i++) {
            var el = list[i];
            var r = el.getBoundingClientRect();
            if (r.width < 100 || r.height < 100) continue;
            var st = window.getComputedStyle(el);
            if (st.display === 'none' || st.visibility === 'hidden') continue;
            if (parseFloat(st.opacity || '1') < 0.1) continue;
            var a = r.width * r.height;
            var hint = ((el.className || '') + ' ' + (el.src || '')).toLowerCase();
            if (hint.indexOf('qr') >= 0) a = a * 20;
            if (a > bestArea) { bestArea = a; best = el; }
          }
          if (!best) return 'NONE:imgs=' + document.images.length;
          if (best.tagName === 'CANVAS') {
            try { return best.toDataURL('image/png'); } catch (e) { return 'ERR:canvas'; }
          }
          if (best.src && best.src.length > 20) return best.src;
          return 'ERR:empty:' + (best.className || '');
        })()
        """
        wv.evaluateJavaScript(js) { result, _ in
            guard let src = result as? String, !src.isEmpty else {
                DispatchQueue.main.async { app.toast = "没找到二维码，等它出来再点" }
                return
            }
            if src.hasPrefix("NONE") || src.hasPrefix("ERR") {
                DispatchQueue.main.async { app.toast = "二维码定位失败（\(src)）" }
                return
            }
            Self.loadImage(src) { image in
                guard let image else {
                    DispatchQueue.main.async { app.toast = "二维码读取失败" }
                    return
                }
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else {
                        DispatchQueue.main.async { app.toast = "没有相册权限，去设置里允许一下" }
                        return
                    }
                    PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    } completionHandler: { ok, _ in
                        DispatchQueue.main.async {
                            app.toast = ok
                                ? "二维码已存相册 → 拼多多右上角「扫一扫」→「相册」"
                                : "保存失败"
                            Self.openPdd()
                        }
                    }
                }
            }
        }
    }

    private static func loadImage(_ src: String, completion: @escaping (UIImage?) -> Void) {
        if src.hasPrefix("data:image"), let comma = src.firstIndex(of: ",") {
            let b64 = String(src[src.index(after: comma)...])
            if let data = Data(base64Encoded: b64), let image = UIImage(data: data) {
                completion(image)
                return
            }
            completion(nil)
            return
        }
        guard let url = URL(string: src) else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else {
                completion(nil)
                return
            }
            completion(image)
        }.resume()
    }

    private static func openPdd() {
        // 只打开拼多多本体；深链进扫一扫的地址不可靠（会落在「界面刷新失败」页）
        let candidates = [
            "pinduoduo://com.xunmeng.pinduoduo",
            "pinduoduo://"
        ]
        openFirst(candidates)
    }

    private static func openFirst(_ list: [String]) {
        guard let head = list.first, let url = URL(string: head) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok { openFirst(Array(list.dropFirst())) }
        }
    }
}
