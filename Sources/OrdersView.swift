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
            .sheet(item: $selected) { order in
                LogisticsSheet(order: order)
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

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(order.statusRaw.isEmpty ? order.status.label : order.statusRaw)
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
                } else {
                    Color.clear.frame(height: pillHeight)
                }
            }
            .frame(height: rowHeight)

            if !order.logistics.isEmpty {
                Button { onLogisticsTap() } label: {
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
                .buttonStyle(.plain)
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
        .frame(width: imageSide, height: rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text(order.platform.short)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(platformBadgeColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color(.systemBackground), lineWidth: 1.5)
                )
                .offset(x: -4, y: -4)
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
    @State private var loading = true
    @State private var message = ""

    @State private var mapHeight: CGFloat = 230
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
                                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
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
                                                .foregroundStyle(index == 0 ? .primary : .secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if !event.time.isEmpty {
                                                Text(event.time)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        .padding(.bottom, 16)
                                        Spacer(minLength: 0)
                                    }
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

    private func load() async {
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

        let names = ShipTracking.placeNames(in: events)
        if !names.isEmpty {
            coordinates = await ShipTracking.coordinates(for: names)
        }
        if !coordinates.isEmpty {
            loading = false
            path = await RoutePlanner.path(through: coordinates)

            if !address.isEmpty,
               let target = await ShipTracking.coordinates(for: [address]).first {
                remaining = await RoutePlanner.path(through: [coordinates.last!, target])
            }
        }
        loading = false
    }
}
