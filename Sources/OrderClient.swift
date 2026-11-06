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

enum OrderClient {
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

        try? capture.text.data(using: .utf8)?.write(to: pageFile(for: .pdd))
        try? capture.payloadJSON.data(using: .utf8)?.write(to: payloadFile(for: .pdd))

        let orders = PinduoduoParser.parse(text: capture.text, payloadJSON: capture.payloadJSON)

        let textBytes = capture.text.utf8.count
        let payloadBytes = capture.payloadJSON.utf8.count

        let note: String
        if orders.isEmpty {
            note = "页面文本 \(textBytes) 字节、接口数据 \(payloadBytes) 字节，但没解析出订单"
        } else {
            note = "解析出 \(orders.count) 条订单"
        }

        return FetchOutcome(
            orders: orders,
            httpStatus: 200,
            byteCount: textBytes + payloadBytes,
            rawFileURL: pageFile(for: .pdd),
            note: note
        )
    }

    /// 调试用的可分享文件
    static func debugFiles(for platform: Platform) -> [DebugFile] {
        var items: [DebugFile] = [
            DebugFile(id: "page-\(platform.rawValue)", label: "\(platform.name) · 页面文本", url: pageFile(for: platform)),
            DebugFile(id: "payload-\(platform.rawValue)", label: "\(platform.name) · 接口数据", url: payloadFile(for: platform))
        ]
        let legacy = latestRawFile(for: platform)
        if FileManager.default.fileExists(atPath: legacy.path) {
            items.append(DebugFile(id: "raw-\(platform.rawValue)", label: "\(platform.name) · 旧版原始页面", url: legacy))
        }
        return items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }
}

struct DebugFile: Identifiable {
    let id: String
    let label: String
    let url: URL
}
