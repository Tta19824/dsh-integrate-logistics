import SwiftUI

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

    private var orderList: some View {
        List {
            ForEach(app.orders) { order in
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(order.platform.short)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(platformColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text(order.title.isEmpty ? "（未识别商品名）" : order.title)
                    .font(.subheadline)
                    .lineLimit(2)

                Spacer(minLength: 0)

                if !order.amount.isEmpty {
                    Text("¥\(order.amount)")
                        .font(.subheadline.monospacedDigit())
                }
            }

            HStack(spacing: 6) {
                Label(order.status.label, systemImage: order.status.symbol)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())

                if !order.statusRaw.isEmpty {
                    Text(order.statusRaw)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !order.orderTime.isEmpty {
                    Text(order.orderTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !order.orderNo.isEmpty {
                Text("订单号 \(order.orderNo)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !order.shopName.isEmpty || !order.logistics.isEmpty {
                HStack(spacing: 8) {
                    if !order.shopName.isEmpty {
                        Text(order.shopName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !order.logistics.isEmpty {
                        Text(order.logistics)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
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
    @State private var lines: [String] = []
    @State private var raw = ""
    @State private var showRaw = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在打开订单页…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !pickup.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("取件码").font(.caption).foregroundStyle(.secondary)
                            Text(pickup)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if !lines.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("物流").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 5))
                                        .padding(.top, 5)
                                        .foregroundStyle(.secondary)
                                    Text(line).font(.footnote)
                                }
                            }
                        }
                    }
                    if !raw.isEmpty {
                        DisclosureGroup("页面原文", isExpanded: $showRaw) {
                            Text(raw)
                                .font(.caption2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(order.title.isEmpty ? "（未识别商品名）" : order.title).font(.headline)
            HStack(spacing: 8) {
                Text(order.statusRaw.isEmpty ? order.status.label : order.statusRaw)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !order.amount.isEmpty {
                    Text("¥\(order.amount)").font(.caption).foregroundStyle(.secondary)
                }
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
            pickup = DetailParser.pickupCode(from: cap.text)
            lines = DetailParser.logisticsLines(from: cap.text)
            if lines.isEmpty && pickup.isEmpty {
                message = "没读到物流信息，可能这单还没发货，或者页面结构变了"
            }
        } catch {
            loading = false
            message = "打开失败：\(error)"
        }
    }
}
