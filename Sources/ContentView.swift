import SwiftUI
import UIKit
import WebKit
import Photos

final class WebHandle: ObservableObject {
    weak var view: WKWebView?
}

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
    @StateObject private var handle = WebHandle()

    var body: some View {
        NavigationStack {
            WebView(
                url: platform.loginURL,
                desktop: platform == .pdd,
                clearDomains: platform == .pdd ? ["pinduoduo.com", "yangkeduo.com"] : [],
                autoQR: platform == .pdd,
                onReady: { handle.view = $0 }
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

    // MARK: - 保存二维码 + 跳到拼多多扫一扫

    private func saveQRAndScan() {
        guard let wv = handle.view else {
            app.toast = "页面还没加载好"
            return
        }
        let js = """
        (function(){
          var i = document.querySelector('.qrcode-login img')
               || document.querySelector('.qrcode-login canvas');
          if (!i) return '';
          if (i.tagName === 'CANVAS') { try { return i.toDataURL('image/png'); } catch (e) { return ''; } }
          return i.src || '';
        })()
        """
        wv.evaluateJavaScript(js) { result, _ in
            guard let src = result as? String, !src.isEmpty else {
                DispatchQueue.main.async { app.toast = "没找到二维码，等它出来再点" }
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
                            app.toast = ok ? "二维码已存相册，接着打开拼多多扫一扫" : "保存失败"
                            Self.openPddScan()
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

    private static func openPddScan() {
        let candidates = [
            "pinduoduo://com.xunmeng.pinduoduo/scan",
            "pinduoduo://com.xunmeng.pinduoduo/qrcode_scan",
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
