import SwiftUI
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
            .sheet(item: $selected) { order in
                OrderDetailSheet(order: order)
                    .environmentObject(app)
            }
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
            .refreshable { app.refreshAll() }
        }
    }

    private var activeOrders: [Order] {
        app.orders.filter { $0.status == .paid || $0.status == .shipped }
    }

    private var orderList: some View {
        List {
            ForEach(activeOrders) { order in
                OrderRow(order: order)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = order }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(order.title.isEmpty ? "（未识别商品名）" : order.title)
                            .font(.subheadline)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)

                        Text(order.statusRaw.isEmpty ? order.status.label : order.statusRaw)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusColor.opacity(0.14))
                            .foregroundStyle(statusColor)
                            .clipShape(Capsule())
                            .fixedSize()
                    }

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
                    }

                    if !order.shopName.isEmpty {
                        Text(order.shopName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            if !order.logistics.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "truck.box")
                        .font(.system(size: 13))
                        .foregroundStyle(statusColor)
                        .frame(width: 22, height: 18)
                    Text(order.logistics)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

        }
        .padding(.vertical, 6)
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
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

struct OrderDetailSheet: View {
    let order: Order
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var message = ""
    @State private var pickup = ""
    @State private var statusWord = ""
    @State private var trackingNo = ""
    @State private var shop = ""
    @State private var trace: [TraceEntry] = []
    @State private var raw = ""
    @State private var showRaw = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if loading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在打开订单页…").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }

                    if !pickup.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("取件码").font(.caption).foregroundStyle(.secondary)
                            Text(pickup)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("到驿站报这个码取件")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if !trace.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(trace.enumerated()), id: \.element.id) { index, item in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(spacing: 0) {
                                        Circle()
                                            .fill(index == 0 ? Color.green : Color(.systemGray4))
                                            .frame(width: index == 0 ? 9 : 7, height: index == 0 ? 9 : 7)
                                            .padding(.top, 4)
                                        if index != trace.count - 1 {
                                            Rectangle()
                                                .fill(Color(.systemGray5))
                                                .frame(width: 1)
                                                .frame(maxHeight: .infinity)
                                        }
                                    }
                                    .frame(width: 10)

                                    VStack(alignment: .leading, spacing: 3) {
                                        if !item.time.isEmpty {
                                            Text(item.time)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                        Text(item.text)
                                            .font(index == 0 ? .footnote.weight(.medium) : .footnote)
                                            .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                                    }
                                    .padding(.bottom, 14)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }

                    if !trackingNo.isEmpty || !order.shopName.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if !order.shopName.isEmpty {
                                row("店铺", order.shopName)
                            }
                            if !trackingNo.isEmpty {
                                HStack {
                                    row("快递单号", trackingNo)
                                    Button {
                                        UIPasteboard.general.string = trackingNo
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if !raw.isEmpty {
                        DisclosureGroup("页面原文", isExpanded: $showRaw) {
                            Text(raw)
                                .font(.caption2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                        .font(.footnote)
                    }
                }
                .padding(16)
            }
            .navigationTitle("订单详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(statusWord.isEmpty ? (order.statusRaw.isEmpty ? order.status.label : order.statusRaw) : statusWord)
                    .font(.title3.bold())
                Spacer()
                if !order.amount.isEmpty {
                    Text("¥\(order.amount)")
                        .font(.headline.monospacedDigit())
                }
            }
            Text(order.title.isEmpty ? "（未识别商品名）" : order.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !shop.isEmpty {
                Text("店铺 \(shop)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("订单号 \(order.orderNo)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func load() async {
        guard order.platform == .pdd else {
            message = "这个平台还没接详情页"
            loading = false
            return
        }
        let cookie = await CookieStore.currentHeader(for: .pdd) ?? ""
        do {
            let cap = try await WebOrderFetcher.shared.captureDetail(orderNo: order.orderNo, cookieHeader: cookie)
            loading = false
            if cap.landedOnLogin {
                message = "登录态失效了，先去平台页重新登录"
                return
            }
            raw = cap.text
            // 详情页的接口数据存一份，方便「平台页 → 调试」里分享出来排查
            let detailURL = OrderClient.detailPayloadFile(for: .pdd)
            try? cap.payloadJSON.data(using: .utf8)?.write(to: detailURL, options: .atomic)
            var realShop = DetailParser.shopName(payloadJSON: cap.payloadJSON, text: cap.text)
            // 订单接口里的店铺常常是品牌馆名（「百亿补贴·宝格丽」），真店名要去商品页捞。
            if !DetailParser.isLikelyShop(realShop), !order.goodsID.isEmpty,
               let g = try? await WebOrderFetcher.shared.captureGoods(goodsID: order.goodsID, cookieHeader: cookie) {
                let fromGoods = DetailParser.shopName(payloadJSON: g.payloadJSON, text: g.text)
                if DetailParser.isLikelyShop(fromGoods) {
                    realShop = fromGoods
                    try? g.payloadJSON.data(using: .utf8)?.write(to: OrderClient.detailPayloadFile(for: .pdd), options: .atomic)
                }
            }
            shop = realShop.isEmpty ? order.shopName : realShop
            pickup = DetailParser.pickupCode(from: cap.text)
            statusWord = DetailParser.statusWord(from: cap.text)
            trackingNo = DetailParser.trackingNumber(from: cap.text)
            trace = DetailParser.trace(from: cap.text)
            if trace.isEmpty && pickup.isEmpty {
                message = "没读到物流信息，可能这单还没发货，或者页面结构变了"
            }
        } catch {
            loading = false
            message = "打开失败：\(error)"
        }
    }
}
