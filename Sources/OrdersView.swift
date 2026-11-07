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
                OrderRow(order: order)
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

                    HStack(spacing: 8) {
                        if !order.shopName.isEmpty {
                            Text(order.shopName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
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
                        }
                    }
                }
            }

            if !order.logistics.isEmpty {
                Button { selected = order } label: {
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

struct LogisticsSheet: View {
    let order: Order
    @Environment(\.dismiss) private var dismiss
    @State private var trace: [TraceEntry] = []
    @State private var loading = true
    @State private var message = ""
    @State private var carrier = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if loading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读物流轨迹…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !trace.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(trace.enumerated()), id: \.element.id) { index, entry in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(spacing: 0) {
                                        Circle()
                                            .fill(index == 0 ? Color.green : Color(.systemGray4))
                                            .frame(width: 8, height: 8)
                                            .padding(.top, 5)
                                        Rectangle()
                                            .fill(Color(.systemGray5))
                                            .frame(width: 1)
                                            .frame(maxHeight: .infinity)
                                    }
                                    .frame(width: 8)

                                    VStack(alignment: .leading, spacing: 3) {
                                        if !entry.time.isEmpty {
                                            Text(entry.time)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text(entry.text)
                                            .font(.footnote)
                                            .foregroundStyle(index == 0 ? .primary : .secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.bottom, 14)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(16)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(carrier.isEmpty ? (order.carrier.isEmpty ? "物流" : order.carrier) : carrier)
                    .font(.headline)
                if !order.pickupCode.isEmpty {
                    Text("取件码 \(order.pickupCode)")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
            }

            Text(order.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text("订单号 \(order.orderNo)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func load() async {
        guard let cookie = await CookieStore.currentHeader(for: .pdd), !cookie.isEmpty else {
            message = "还没登录拼多多，先去「平台」页登录"
            loading = false
            return
        }
        do {
            let capture = try await WebOrderFetcher.shared.captureDetail(orderNo: order.orderNo, cookieHeader: cookie)
            let entries = DetailParser.trace(from: capture.text)
            trace = entries
            if carrier.isEmpty {
                carrier = PinduoduoParser.carrierName(from: capture.text) ?? order.carrier
            }
            if entries.isEmpty { message = "没读到轨迹，可能这单还没发出" }
        } catch {
            message = "打开物流页失败：\(error)"
        }
        loading = false
    }
}

