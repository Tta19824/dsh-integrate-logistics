import Foundation

struct FetchOutcome {
    var orders: [Order]
    var httpStatus: Int
    var byteCount: Int
    var rawFileURL: URL?
    var note: String
}

enum FetchError: LocalizedError {
    case noCookie
    case badURL
    case http(Int)
    case emptyBody
    case note(String)

    var errorDescription: String? {
        switch self {
        case .noCookie: return "还没有登录，先点「登录」拿到 cookie"
        case .badURL: return "地址拼错了"
        case .http(let code): return "服务器返回 \(code)"
        case .emptyBody: return "页面是空的"
        case .note(let text): return text
        }
    }
}

/// 上一次抓包的诊断信息，给「平台」页显示，方便截图定位问题
struct CaptureInfo {
    var entryCount = 0
    var textChars = 0
    var payloadChars = 0
    var urls: [String] = []
    var largestBody = ""
    var writeError = ""
}

enum OrderClient {
    static var lastCapture = CaptureInfo()

    static func rawDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func latestRawFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("raw_\(platform.rawValue).html")
    }

    static func pageFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("page_\(platform.rawValue).txt")
    }

    static func payloadFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("payload_\(platform.rawValue).json")
    }

    static func fetch(platform: Platform) async throws -> FetchOutcome {
        guard let cookie = CookieStore.load(for: platform), !cookie.isEmpty else {
            throw FetchError.noCookie
        }
        switch platform {
        case .pdd:
            return try await fetchPinduoduo(cookie: cookie)
        case .tb, .jd:
            throw FetchError.note("\(platform.name) 的抓取还在开发中，下个版本加")
        }
    }

    /// 用真 WebView 打开订单页，让平台自己的 JS 去请求数据，再把渲染结果和接口响应抓回来。
    private static func fetchPinduoduo(cookie: String) async throws -> FetchOutcome {
        guard let url = URL(string: "https://mobile.pinduoduo.com/order.html") else {
            throw FetchError.badURL
        }

        let capture = try await WebOrderFetcher.shared.capture(url: url)

        var info = CaptureInfo()
        info.textChars = capture.text.count
        info.payloadChars = capture.payloadJSON.count

        let pageErr = write(capture.text, to: pageFile(for: .pdd))
        let payloadErr = write(capture.payloadJSON, to: payloadFile(for: .pdd))
        info.writeError = [pageErr, payloadErr].compactMap { $0 }.joined(separator: " / ")

        if let data = capture.payloadJSON.data(using: .utf8),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            info.entryCount = entries.count
            var largest = ""
            for entry in entries {
                let path = urlPath(entry["u"] as? String ?? "")
                if !path.isEmpty, !info.urls.contains(path) { info.urls.append(path) }
                if let body = entry["b"] as? String, body.count > largest.count { largest = body }
            }
            info.urls = Array(info.urls.prefix(8))
            info.largestBody = largest
        }
        lastCapture = info

        let orders = PinduoduoParser.parse(text: capture.text, payloadJSON: capture.payloadJSON)

        var note = info.entryCount > 0
            ? "抓到 \(info.entryCount) 个接口响应，解析出 \(orders.count) 条订单"
            : "没抓到接口响应，页面文本 \(info.textChars) 字"
        if !info.writeError.isEmpty { note += "；文件写入失败：\(info.writeError)" }

        return FetchOutcome(
            orders: orders,
            httpStatus: 200,
            byteCount: info.textChars + info.payloadChars,
            rawFileURL: payloadFile(for: .pdd),
            note: note
        )
    }

    private static func write(_ text: String, to url: URL) -> String? {
        // JS 字符串里可能带孤立代理项，utf8 编码会直接返回 nil，退回 utf16
        let data = text.data(using: .utf8) ?? text.data(using: .utf16)
        guard let data else { return "编码失败" }
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func urlPath(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return String(raw.prefix(80)) }
        let path = url.path
        if path.isEmpty { return url.host ?? "" }
        return "\(url.host ?? "")\(path)"
    }

    /// 调试用的可分享文件（不存在的也列出来，由界面显示「未生成」）
    static func debugFiles(for platform: Platform) -> [DebugFile] {
        [
            DebugFile(id: "page-\(platform.rawValue)", label: "\(platform.name) · 页面文本", url: pageFile(for: platform)),
            DebugFile(id: "payload-\(platform.rawValue)", label: "\(platform.name) · 接口数据", url: payloadFile(for: platform)),
            DebugFile(id: "raw-\(platform.rawValue)", label: "\(platform.name) · 旧版原始页面", url: latestRawFile(for: platform))
        ]
    }
}

struct DebugFile: Identifiable {
    let id: String
    let label: String
    let url: URL
}
