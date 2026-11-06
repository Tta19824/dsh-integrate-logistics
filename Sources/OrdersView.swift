import SwiftUI

struct OrdersView: View {
    @EnvironmentObject private var app: AppState

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
            .refreshable { app.refreshAll() }
        }
    }

    private var orderList: some View {
        List {
            ForEach(app.orders) { order in
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
