import SwiftUI
import CoreLocation
import UIKit

struct OrdersView: View {
    @EnvironmentObject private var app: AppState
    @State private var selected: Order?

    var body: some View {
        NavigationStack {
            Group {
                if app.orders.isEmpty {
                    emptyState
                } else {
                    orderList
                }
            }
            .navigationTitle("我的订单")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let busy = app.busy {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text(busy.name).font(.caption)
                        }
                    } else {
                        Button {
                            app.refreshAll()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(item: $selected, onDismiss: { app.reload() }) { order in
                LogisticsSheet(order: order)
            }
            .refreshable { app.refreshAll() }
        }
    }

    private var activeOrders: [Order] {
        app.orders.filter { order in
            let raw = order.statusRaw
            // 退款 / 退货 / 取消 / 关闭的单子一律不进这个列表。
            // 0.36.11 加兜底时没排掉它们：一张已经退货的淘宝单因为还留着取件码，
            // 又被「!pickupCode.isEmpty」捞回来了（2026-11-19 实测）。
            if order.status == .cancelled || order.status == .refunding { return false }
            if raw.contains("退款") || raw.contains("退货") || raw.contains("取消") || raw.contains("关闭") {
                return false
            }
            if order.status == .paid || order.status == .shipped { return true }
            // 兜底只对京东生效：状态词没认出来、但明显是「到了驿站等人取」的单子也得留着。
            // 以前这里只放 待付款/待收货，京东写「请上门自提」时整条被藏掉（0.36.10 实测）。
            guard order.platform == .jd else { return false }
            if !order.pickupCode.isEmpty { return true }
            return raw.contains("自提") || raw.contains("取件") || raw.contains("到站") || raw.contains("投递")
        }
    }

    private var orderList: some View {
        List {
            ForEach(activeOrders) { order in
                OrderRow(order: order) { selected = order }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("还没有订单")
                .font(.headline)
            Text("去「平台」页登录，然后点刷新")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

struct OrderRow: View {
    let order: Order
    var onLogisticsTap: () -> Void = {}

    private let imageSide: CGFloat = 84
    private let rowHeight: CGFloat = 84
    private let titleHeight: CGFloat = 42
    private let timeHeight: CGFloat = 18
    private let pillHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail

                    VStack(alignment: .leading, spacing: 0) {
                        Text(order.title.isEmpty ? "（未识别商品名）" : order.title)
                            .font(.subheadline)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: titleHeight, alignment: .topLeading)

                        HStack(spacing: 10) {
                            if !order.orderTime.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 10))
                                    Text(order.orderTime)
                                        .font(.caption2)
                                }
                                .foregroundStyle(.secondary)
                            }
                            if !order.amount.isEmpty {
                                Text("¥\(order.amount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: timeHeight, alignment: .leading)

                        Spacer(minLength: 0)
                    }
                    .frame(height: rowHeight)

                    Button {
                        PddLink.open(platform: order.platform, orderNo: order.orderNo, itemID: order.goodsID)
                    } label: {
                        VStack(alignment: .center, spacing: 3) {
                            Text(order.shortStatusText)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(statusColor.opacity(0.14))
                                .foregroundStyle(statusColor)
                                .clipShape(Capsule())
                                .fixedSize()
                            if !order.carrier.isEmpty {
                                Text(order.carrier)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: rowHeight, alignment: .center)
                        .frame(minWidth: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(y: -3)
                }
                .frame(height: rowHeight)

                if !order.pickupCode.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 9))
                        Text("取件码 \(order.pickupCode)")
                            .font(.caption2.bold())
                            .fixedSize()
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .frame(height: pillHeight)
                    .offset(y: 2)
                } else {
                    Color.clear.frame(height: pillHeight)
                }
            }
            .frame(height: rowHeight)

            Button { onLogisticsTap() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "truck.box")
                            .font(.system(size: 13))
                            .foregroundStyle(statusColor)
                            .frame(width: 22, height: 18)
                        Text(order.logistics.isEmpty ? placeholderLogisticsText : order.logistics)
                            .font(.caption)
                            .foregroundStyle(order.logistics.isEmpty ? Color.secondary.opacity(0.7) : .secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    /// 没有物流时卡片也要占位说明，别整块消失
    private var placeholderLogisticsText: String {
        switch order.status {
        case .paid: return "卖家还没发货，发货后会显示物流"
        case .shipped: return "物流信息还没更新，稍后再看"
        case .completed: return "这单已完成，没有物流轨迹"
        case .cancelled: return "订单已取消"
        default: return "暂无物流信息"
        }
    }

    private var thumbnail: some View {
        AsyncImage(url: thumbURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: imageSide, height: rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text(order.platform.short)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(platformBadgeColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color(.systemBackground), lineWidth: 1.5)
                )
                .offset(x: -5, y: -5)
        }
    }

    private var platformBadgeColor: Color {
        switch order.platform {
        case .pdd: return Color(red: 0.90, green: 0.13, blue: 0.17)
        case .tb: return Color(red: 1.00, green: 0.42, blue: 0.05)
        case .jd: return Color(red: 0.90, green: 0.13, blue: 0.15)
        }
    }

    private var thumbURL: URL? {
        var s = order.imageURL.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        return URL(string: s)
    }

    private var platformColor: Color {
        switch order.platform {
        case .pdd: return .red
        case .tb: return .orange
        case .jd: return .red
        }
    }

    private var statusColor: Color {
        switch order.status {
        case .shipped: return .blue
        case .paid: return .orange
        case .completed: return .green
        case .cancelled: return .gray
        case .refunding: return .purple
        case .unpaid: return .red
        case .unknown: return .gray
        }
    }
}

struct LogisticsSheet: View {
    let order: Order
    @Environment(\.dismiss) private var dismiss
    @State private var events: [ShipEvent] = []
    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var path: [CLLocationCoordinate2D] = []
    @State private var remaining: [CLLocationCoordinate2D] = []
    @State private var tracking = ""
    @State private var carrierLine = ""
    @State private var loading = true
    @State private var message = ""
    /// 京东的取件码只写在订单详情页里（列表接口没有这个字段），读到就存库
    @State private var pickup = ""

    @State private var mapHeight: CGFloat = 230
    @State private var traceExpanded = false
    private var visibleEvents: [ShipEvent] {
        if traceExpanded || events.count <= 2 { return events }
        return Array(events.prefix(2))
    }
    @State private var dragStart: CGFloat?

    private var brief: (title: String, subtitle: String, stage: String, eta: String) {
        ShipTracking.summary(from: events)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    RouteMapView(
                        path: path,
                        remaining: remaining,
                        truck: coordinates.last,
                        caption: brief.title,
                        subcaption: brief.subtitle
                    )
                    .frame(height: mapHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    mapGrabber
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !pickup.isEmpty {
                            pickupRow
                                .padding(.horizontal, 16)
                                .padding(.top, 6)
                        }

                        trackingRow
                            .padding(.horizontal, 16)
                            .padding(.top, 2)

                        if loading {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在读物流轨迹…").font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(16)
                        } else if !message.isEmpty {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }

                        if !events.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, event in
                                    self.eventRow(index: index, event: event)
                                }

                                if events.count > 2 {
                                    expandButton
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationTitle("物流详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func eventRow(index: Int, event: ShipEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(index == 0 ? Color.green : Color(.systemGray4))
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.desc)
                    .font(.footnote)
                    .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !event.time.isEmpty {
                    Text(event.time)
                        .font(.caption2)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .padding(.bottom, 16)

            Spacer(minLength: 0)
        }
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { traceExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(traceExpanded ? "收起" : "展开全部 \(events.count) 条")
                    .font(.footnote)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(traceExpanded ? 180 : 0))
            }
            .foregroundStyle(Color.blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    /// 地图下沿的小横条：按住上下拖，调地图高度。
    private var mapGrabber: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 44, height: 5)
            Spacer()
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = mapHeight }
                    let base = dragStart ?? mapHeight
                    mapHeight = min(max(base + value.translation.height, 140), 560)
                }
                .onEnded { _ in dragStart = nil }
        )
        .accessibilityLabel("拖动调整地图大小")
    }

    /// 取件码：驿站/自提单才有。点一下复制，去驿站直接念数字。
    private var pickupRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
            Text("取件码")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(pickup)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = pickup
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var trackingRow: some View {
        HStack(spacing: 8) {
            Text("快递单号")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tracking.isEmpty ? "暂未获取" : tracking)
                .font(.caption.monospacedDigit())
                .foregroundStyle(tracking.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if !costLabel.isEmpty {
                Text(costLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if !tracking.isEmpty {
                Button {
                    UIPasteboard.general.string = tracking
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// 淘宝：详情页文字 + 物流轨迹页接口，两份都试，取轨迹更全的那份。
    @State private var costLabel = ""

    /// 京东：订单详情页里的物流轨迹
    private func loadJD() async {
        let cacheKey = "jd:\(order.orderNo)"
        if !order.pickupCode.isEmpty { pickup = order.pickupCode }
        // 缓存只在「真攒到轨迹」时才算数：以前连「等待京东发货」这种占位也缓存，
        // 结果点进来永远是那句占位，看起来就是「物流详情数据不对」。
        if let cached = TraceCache.shared.get(cacheKey),
           cached.events.count > 1 || !cached.tracking.isEmpty {
            events = cached.events
            tracking = cached.tracking
            carrierLine = cached.carrier.isEmpty ? order.carrier : cached.carrier
            loading = false
            await refreshRoute()
            return
        }
        // 京东只走电脑版：详情页也用 thor/pin，不再碰手机版 pt_key。
        let pcCookie = CookieStore.loadPc(for: .jd) ?? ""
        guard !pcCookie.isEmpty else {
            message = "京东还没登录电脑版，先去「平台」页点「电脑版登录」"
            loading = false
            return
        }
        guard let detail = await OrderClient.jdPCDetail(orderNo: order.orderNo, cookieHeader: pcCookie) else {
            message = "没打开京东订单详情页"
            loading = false
            return
        }
        // 详情页原样落盘（带 URL，方便一眼看出这次是不是真的进了 details.jd.com）
        let dumpHead = "【版本】\(OrderClient.appVersion())\n【详情URL】\(detail.url)\n【字数】\(detail.text.count)\n\n"
        try? (dumpHead + detail.text).data(using: .utf8)?
            .write(to: OrderClient.jdDetailFile(for: .jd), options: .atomic)
        let capText = detail.text
        // 京东把没登录的 WebView 渲染成「你好，请登录 / 账号信息获取失败」，那不是订单详情，
        // 更不是物流轨迹 —— 直接说清楚，别拿它拼出几条假进度。
        let blocked = capText.contains("账号信息获取失败")
            || capText.contains("快速验证")
            || capText.contains("免费注册")
        if blocked {
            message = "京东这个页面没认登录态（显示「请登录 / 账号信息获取失败」）。先去「平台」页把京东登录一下再回来"
            loading = false
            return
        }
        let parsed = TaobaoJdParser.parseJdLogistics(text: capText, payloadJSON: "")
        events = parsed.events
        tracking = parsed.tracking
        carrierLine = parsed.carrier.isEmpty ? order.carrier : parsed.carrier
        // 取件码只在这个页面里有：读到就显示 + 存库，列表卡片下次刷新也能直接带上
        if pickup.isEmpty {
            pickup = DetailParser.pickupCode(from: capText)
        }
        if pickup.isEmpty {
            pickup = DetailParser.pickupCode(from: events.map(\.desc).joined(separator: "\n"))
        }
        if !pickup.isEmpty, pickup != order.pickupCode {
            OrderStore.shared.setPickup(orderNo: order.orderNo, code: pickup)
        }
        if events.isEmpty {
            // 还没发货：京东列表接口只给「正在出库 / 仓库处理中」这类摘要，
            // 拿摘要当一条进度，别让详情页空着。
            let latest = order.logistics.isEmpty ? "等待京东发货，发货后会自动更新" : order.logistics
            events = [ShipEvent(id: 0, time: "", desc: latest)]
            message = "这单还没发货，先显示最新进度"
            // 占位不进缓存：进了缓存下次点进来就永远看不到真实轨迹了
            loading = false
            await refreshRoute()
            return
        }
        TraceCache.shared.put(cacheKey, TraceCache.Item(at: Date(), events: events, tracking: tracking, carrier: carrierLine))
        if let latest = events.first, !latest.desc.isEmpty {
            OrderStore.shared.setTrace(orderNo: order.orderNo, text: latest.desc)
        }
        loading = false
        await refreshRoute()
    }

    private func loadTaobao() async {
        let cacheKey = "tb:\(order.orderNo)"
        // 缓存只跳过「已经有取件码」的情况：没有码说明这张单还没读过物流页，
        // 得再抓一次把码拿回来（缓存里没有码）。
        if let cached = TraceCache.shared.get(cacheKey), !order.pickupCode.isEmpty {
            events = cached.events
            tracking = cached.tracking
            carrierLine = cached.carrier.isEmpty ? order.carrier : cached.carrier
            loading = false
            // 缓存只存了轨迹，路线要重新算，否则第二次进来地图是空的
            await refreshRoute()
            return
        }
        guard let cookie = await CookieStore.currentHeader(for: .tb), !cookie.isEmpty else {
            message = "还没登录淘宝，先去「平台」页登录"
            loading = false
            return
        }

        var capturedChars = 0
        var capturedText = ""
        var landedURL = ""
        var loggedSecond = ""
        var followedURL = ""
        var logisticsLanding = ""
        let openedAt = Date()
        var best = TaobaoJdParser.TbLogistics()
        var pickupCandidate = ""

        // 快路：先用 URLSession 带着 cookie 直接请求物流页。
        // 如果服务端把节点直接渲染在 HTML 里，就不用开 WebView（省 4 秒）。
        if let rawHTML = await TaobaoLogistics.rawHTML(orderNo: order.orderNo, cookieHeader: cookie) {
            try? rawHTML.data(using: .utf8)?.write(to: OrderClient.tbRawHTMLFile(for: .tb), options: .atomic)
            let fastEvents = TaobaoJdParser.parseTaobaoTraceHTML(rawHTML)
            if fastEvents.count >= 2 {
                best.events = fastEvents
                best.pickup = TaobaoJdParser.tbPickup(in: rawHTML)
                best.tracking = TaobaoJdParser.trackingNumber(fromLogisticsHTML: rawHTML)
                let carrier = PinduoduoParser.carrierName(from: rawHTML) ?? ""
                if !carrier.isEmpty { best.carrier = carrier }
                capturedText = rawHTML
                capturedChars = rawHTML.count
                landedURL = "直连HTML"
            }
        }

        // 慢路径：直接开物流轨迹页：它的 mtop 响应走 JSONP，钩子能抓到全量轨迹，比解析页面文字靠谱
        if best.events.count < 3,
           let capL = try? await WebOrderFetcher.shared.captureTaobaoLogistics(orderNo: order.orderNo, cookieHeader: cookie) {
            var whole = TaobaoJdParser.parseTaobaoLogistics(payloadJSON: capL.payloadJSON, text: capL.text)
            let fromHTML = TaobaoJdParser.parseTaobaoTraceHTML(capL.html)
            if whole.pickup.isEmpty { whole.pickup = TaobaoJdParser.tbPickup(in: capL.html) }
            if pickupCandidate.isEmpty, !whole.pickup.isEmpty { pickupCandidate = whole.pickup }
            if fromHTML.count > whole.events.count {
                whole.events = fromHTML
                if whole.carrier.isEmpty { whole.carrier = order.carrier }
            }
            if whole.tracking.isEmpty {
                whole.tracking = TaobaoJdParser.trackingNumber(fromText: capL.text)
            }
            if whole.tracking.isEmpty {
                whole.tracking = TaobaoJdParser.trackingNumber(fromLogisticsHTML: capL.html)
            }
            if whole.events.count > 1 {
                best = whole
                capturedText = capL.text
                capturedChars = capL.text.count
                landedURL = capL.finalURL
            }
            try? capL.payloadJSON.data(using: .utf8)?.write(to: OrderClient.tbLogisticsFile(for: .tb), options: .atomic)
            if let reqJSON = TaobaoJdParser.extractMtopRequests(payloadJSON: capL.payloadJSON) {
                try? reqJSON.data(using: .utf8)?.write(to: OrderClient.tbRequestsFile(for: .tb), options: .atomic)
            }
            try? capL.resources.data(using: .utf8)?.write(to: OrderClient.resourcesFile(for: .tb), options: .atomic)
            try? capL.html.data(using: .utf8)?.write(to: OrderClient.tbLogisticsHTMLFile(for: .tb), options: .atomic)
            logisticsLanding = capL.finalURL
        }

        if best.events.count < 3,
           let cap = try? await WebOrderFetcher.shared.captureTaobaoDetail(orderNo: order.orderNo, cookieHeader: cookie) {
            capturedChars = cap.text.count
            capturedText = cap.text
            landedURL = cap.finalURL
            followedURL = cap.followedURL
            try? cap.text.data(using: .utf8)?.write(to: OrderClient.tbDetailFile(for: .tb), options: .atomic)
            try? cap.payloadJSON.data(using: .utf8)?.write(to: OrderClient.tbLogisticsFile(for: .tb), options: .atomic)
            try? cap.resources.data(using: .utf8)?.write(to: OrderClient.resourcesDetailFile(for: .tb), options: .atomic)
            let one = TaobaoJdParser.parseTaobaoLogistics(payloadJSON: cap.payloadJSON, text: cap.text)
            if one.events.count > best.events.count {
                best = one
                capturedText = cap.text
                capturedChars = cap.text.count
                landedURL = cap.finalURL
                followedURL = cap.followedURL
            }
        }

        // 轨迹太少就先开 wuliu PC 页（服务端渲染，通常一次给全），再不行才开 mobile 物流页
        if best.events.count < 4,
           let capW = try? await WebOrderFetcher.shared.captureTaobaoWuliu(orderNo: order.orderNo, cookieHeader: cookie) {
            let w = TaobaoJdParser.parseTaobaoLogistics(payloadJSON: capW.payloadJSON, text: capW.text)
            if w.events.count > best.events.count {
                best = w
                capturedText = capW.text
                capturedChars = capW.text.count
            }
            try? capW.text.data(using: .utf8)?.write(to: OrderClient.tbDetailFile(for: .tb), options: .atomic)
        }

        if best.events.isEmpty,
           let cap2 = try? await WebOrderFetcher.shared.captureTaobaoLogistics(orderNo: order.orderNo, cookieHeader: cookie) {
            try? cap2.text.data(using: .utf8)?.write(to: OrderClient.tbLogisticsFile(for: .tb), options: .atomic)
            let second = TaobaoJdParser.parseTaobaoLogistics(payloadJSON: cap2.payloadJSON, text: cap2.text)
            if second.events.count > best.events.count { best = second }
            capturedText = cap2.text
            capturedChars = cap2.text.count
            if best.tracking.isEmpty { best.tracking = second.tracking }
            if best.carrier.isEmpty { best.carrier = second.carrier }
            loggedSecond = "\(cap2.text.count)"
        }

        events = best.events
        tracking = best.tracking
        // 页面文字里找不到这串数字，说明是从接口里误捞的；宁可不显示，也别显示错的
        if !tracking.isEmpty && !capturedText.isEmpty && !capturedText.contains(tracking) {
            tracking = ""
        }
        if !best.carrier.isEmpty {
            carrierLine = best.carrier
        } else if !order.carrier.isEmpty {
            carrierLine = order.carrier
        }
        if best.pickup.isEmpty { best.pickup = pickupCandidate }
        if !best.pickup.isEmpty {
            OrderStore.shared.setPickup(orderNo: order.orderNo, code: best.pickup)
        }
        if !events.isEmpty {
            TraceCache.shared.put(cacheKey, TraceCache.Item(at: Date(), events: events, tracking: tracking, carrier: carrierLine))
            // 详情页抓到的东西也要落库：之前只有后台补抓会写 trace_summary，
            // 用户手动点开过之后补抓又会被缓存跳过，卡片就一直是摘要。
            if let latest = events.first, !latest.desc.isEmpty {
                OrderStore.shared.setTrace(orderNo: order.orderNo, text: latest.desc)
            }
        }

        if events.isEmpty {
            let landing = landedURL.replacingOccurrences(of: "https://", with: "").prefix(60)
            let followed = followedURL.isEmpty ? "没找到可跟进的链接" : ("跟进 " + followedURL.replacingOccurrences(of: "https://", with: "").prefix(50))
            let extra = loggedSecond.isEmpty ? "" : "｜物流页 \(loggedSecond) 字"
            message = "没读到物流轨迹（\(capturedChars) 字｜落点 \(landing)｜\(followed)\(extra)）"
            loading = false
            return
        }

        let cost = Date().timeIntervalSince(openedAt)
        costLabel = String(format: "%.1f 秒", cost)
        // 轨迹已经拿到了，先结束 loading；地理编码与路径规划慢，留着让地图自己补线
        loading = false
        await refreshRoute()
    }

    /// 由轨迹里的地名算坐标、再求沿公路的折线。缓存命中时也要跑一遍，否则地图空白。
    private func refreshRoute(target: String = "") async {
        let names = ShipTracking.placeNames(in: events)
        guard !names.isEmpty else { return }
        coordinates = await ShipTracking.coordinates(for: names)
        guard !coordinates.isEmpty else { return }
        path = await RoutePlanner.path(through: coordinates)
        if !target.isEmpty,
           let dest = await ShipTracking.coordinates(for: [target]).first,
           let last = coordinates.last {
            remaining = await RoutePlanner.path(through: [last, dest])
        }
    }

    private func load() async {
        if order.platform == .tb {
            await loadTaobao()
            return
        }
        if order.platform == .jd {
            await loadJD()
            return
        }
        guard let cookie = await CookieStore.currentHeader(for: .pdd), !cookie.isEmpty else {
            message = "还没登录拼多多，先去「平台」页登录"
            loading = false
            return
        }

        var address = ""
        if let result = await ShippingClient.track(orderNo: order.orderNo, cookieHeader: cookie) {
            events = result.events
            tracking = result.tracking
            address = result.address
        }

        if events.isEmpty {
            if let capture = try? await WebOrderFetcher.shared.captureDetail(orderNo: order.orderNo, cookieHeader: cookie) {
                events = DetailParser.trace(from: capture.text).map {
                    ShipEvent(id: $0.id, time: $0.time, desc: $0.text)
                }
                if tracking.isEmpty {
                    tracking = DetailParser.trackingNumber(from: capture.text)
                }
                if address.isEmpty {
                    address = ShipTracking.destination(from: Data(capture.text.utf8))
                }
            }
        }

        if events.isEmpty {
            message = "没读到轨迹，可能这单还没发出"
            loading = false
            return
        }

        loading = false
        await refreshRoute(target: address)
    }
}

extension Order {
    /// 接口给的 order_status_prompt 可能是「免拼成功，待发货」这种长句，胶囊里只留关键词。
    var shortStatusText: String {
        switch status {
        case .unpaid: return "待付款"
        case .paid: return "待发货"
        case .shipped: return "待收货"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .refunding: return "退款中"
        case .unknown: break
        }
        let raw = statusRaw
        if raw.isEmpty { return status.label }
        if raw.contains("待发货") || raw.contains("打包") || raw.contains("待出库") { return "待发货" }
        if raw.contains("待收货") || raw.contains("运输中") || raw.contains("派送") || raw.contains("派件") { return "待收货" }
        if raw.contains("待付款") { return "待付款" }
        if raw.contains("退款") || raw.contains("售后") { return "退款中" }
        if raw.contains("取消") || raw.contains("关闭") { return "已取消" }
        if raw.contains("成功") || raw.contains("完成") || raw.contains("已签收") { return "已完成" }
        return raw.count <= 6 ? raw : status.label
    }
}

