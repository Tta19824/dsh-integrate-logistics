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
    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func rawDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func latestRawFile(for platform: Platform) -> URL {
        rawDirectory().appendingPathComponent("raw_\(platform.rawValue).html")
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

    private static func fetchPinduoduo(cookie: String) async throws -> FetchOutcome {
        guard let url = URL(string: "https://mobile.pinduoduo.com/order.html") else {
            throw FetchError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://mobile.pinduoduo.com/", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FetchError.http(status) }
        guard !data.isEmpty else { throw FetchError.emptyBody }

        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf8) ?? ""
        let orders = PinduoduoParser.parse(html: html)

        let file = latestRawFile(for: .pdd)
        try? data.write(to: file)

        let note: String
        if orders.isEmpty {
            note = "拿到 \(data.count) 字节页面，但没解析出订单 —— 页面结构可能变了，把原始页面发给我看看"
        } else {
            note = "解析出 \(orders.count) 条订单"
        }

        return FetchOutcome(
            orders: orders,
            httpStatus: status,
            byteCount: data.count,
            rawFileURL: file,
            note: note
        )
    }
}
