import Foundation
import SwiftUI
import UserNotifications
import BackgroundTasks

/// 后台定时刷新 + 变化通知。
///
/// 设计：
/// - 每次刷新完把「订单当前状态」压成一张快照存进 UserDefaults
/// - 下次刷新后逐单比对，只对「刚发货 / 物流有新节点 / 取件码出现」发通知
/// - 23:00–07:00 静默（不发，等下次刷新再比）
enum BackgroundRefresh {
    static let taskID = "com.abdd.orderpocket.refresh"
    static let snapshotKey = "refresh_snapshot"

    // MARK: - 通知权限

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - 排下一次

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        // 系统最早 30 分钟后可能给一次；实际时间由 iOS 决定
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - 后台跑一次（不依赖界面）

    static func runOnce() async {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: "disabled_platforms") ?? [])
        let platforms = Platform.allCases.filter { p in
            !disabled.contains(p.rawValue) && CookieStore.hasLogin(CookieStore.load(for: p), platform: p)
        }
        if !platforms.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for platform in platforms {
                    group.addTask {
                        guard let outcome = try? await OrderClient.fetch(platform: platform),
                              !outcome.orders.isEmpty else { return }
                        await MainActor.run {
                            OrderStore.shared.replace(platform: platform, with: outcome.orders)
                        }
                    }
                }
            }
        }
        let orders = await MainActor.run { OrderStore.shared.all() }
        let messages = await MainActor.run { diff(orders: orders) }
        await MainActor.run { post(messages) }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_refresh_at")
        schedule()
    }

    // MARK: - 快照与比对

    struct Snapshot: Codable {
        var status: String
        var logistics: String
        var pickup: String
        var title: String
    }

    static func loadSnapshot() -> [String: Snapshot] {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey),
              let map = try? JSONDecoder().decode([String: Snapshot].self, from: data) else { return [:] }
        return map
    }

    static func saveSnapshot(_ map: [String: Snapshot]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: snapshotKey)
    }

    static var quietHours: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 23 || hour < 7
    }

    /// 返回「这次要通知的内容」；同时把快照更新成最新
    @MainActor
    static func diff(orders: [Order]) -> [String] {
        var old = loadSnapshot()
        var fresh: [String: Snapshot] = [:]
        var messages: [String] = []

        for order in orders {
            let key = order.id
            let now = Snapshot(status: order.status.rawValue, logistics: order.logistics, pickup: order.pickupCode, title: order.title)
            fresh[key] = now
            guard let before = old.removeValue(forKey: key) else {
                // 第一次见到的订单不通知（避免装上新版本时刷屏）
                continue
            }
            let shortTitle = order.title.count > 16 ? String(order.title.prefix(16)) + "…" : order.title

            // 取件码出现或变化 —— 最重要
            if !now.pickup.isEmpty && now.pickup != before.pickup {
                messages.append("\(order.platform.short) \(shortTitle)：取件码 \(now.pickup)")
                continue
            }
            // 刚发货
            if before.status == OrderStatus.paid.rawValue, now.status == OrderStatus.shipped.rawValue {
                messages.append("\(order.platform.short) \(shortTitle)：已发货")
                continue
            }
            // 物流有新节点
            if !now.logistics.isEmpty, now.logistics != before.logistics {
                messages.append("\(order.platform.short) \(shortTitle)：\(now.logistics)")
                continue
            }
        }

        saveSnapshot(fresh)
        return messages
    }

    // MARK: - 发通知

    @MainActor
    static func post(_ messages: [String]) {
        guard !messages.isEmpty, !quietHours else { return }
        let center = UNUserNotificationCenter.current()
        // 最多 4 条，避免一次弹一堆
        for text in messages.prefix(4) {
            let content = UNMutableNotificationContent()
            content.title = "订单有更新"
            content.body = text
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}
