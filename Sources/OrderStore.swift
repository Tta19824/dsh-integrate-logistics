import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// 本地订单库。用最朴素的 SQLite，不引入任何第三方依赖。
final class OrderStore {
    static let shared = OrderStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.abdd.orderpocket.store")

    private init() {
        open()
    }

    private var dbPath: String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("orders.sqlite3").path
    }

    private func open() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            NSLog("[store] open failed")
            return
        }
        let sql = """
        CREATE TABLE IF NOT EXISTS orders (
            id TEXT PRIMARY KEY,
            platform TEXT NOT NULL,
            order_no TEXT,
            title TEXT,
            shop TEXT,
            amount TEXT,
            status TEXT,
            status_raw TEXT,
            order_time TEXT,
            logistics TEXT,
            pickup_code TEXT,
            carrier TEXT,
            image_url TEXT,
            goods_id TEXT,
            updated_at REAL
        );
        """
        sqlite3_exec(db, "ALTER TABLE orders ADD COLUMN image_url TEXT;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE orders ADD COLUMN goods_id TEXT;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE orders ADD COLUMN carrier TEXT;", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS trace_summary (order_no TEXT PRIMARY KEY, text TEXT, updated REAL);", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM trace_summary WHERE order_no IS NULL OR order_no = '' OR text IS NULL OR text = '';", nil, nil, nil)
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[store] create table failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// 整平台替换：先清掉这个平台的旧记录，再写入本次抓到的。
    /// 这样接口里已经消失的订单（比如以前兜底解析出来的假记录）不会一直赖着。
    func replace(platform: Platform, with orders: [Order]) {
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "DELETE FROM orders WHERE platform = '\(platform.rawValue)';", nil, nil, nil)
        }
        upsert(orders)
        // 列表接口只给「运输中预计明天送达」这种摘要，写回后又把卡片上的轨迹冲掉了。
        // 这里在 SQL 层把 trace_summary 里的最新轨迹贴回去，跟缓存/内存状态无关。
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, """
                UPDATE orders SET logistics = (SELECT text FROM trace_summary t WHERE t.order_no = orders.order_no)
                WHERE EXISTS (SELECT 1 FROM trace_summary t WHERE t.order_no = orders.order_no);
                """, nil, nil, nil)
        }
    }

    /// 卡片上显示的最新一条轨迹。单独存表：刷新会整平台 DELETE 再写回，
    /// 直接写在 orders.logistics 上会被列表接口的一句话摘要冲掉。
    private(set) var lastTraceError = ""

    /// 平台页「调试 · 轨迹库」用：看这张表到底有没有写进去。
    func traceDebug() -> String {
        queue.sync {
            guard let db else { return "数据库没打开" }
            var count = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM trace_summary;", -1, &stmt, nil) == SQLITE_OK,
               sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            } else {
                return "查 trace_summary 失败：\(String(cString: sqlite3_errmsg(db)))"
            }
            sqlite3_finalize(stmt)

            var sample = ""
            var s2: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT order_no, text FROM trace_summary ORDER BY updated DESC LIMIT 1;", -1, &s2, nil) == SQLITE_OK,
               sqlite3_step(s2) == SQLITE_ROW {
                let no = text(s2, 0)
                let tx = text(s2, 1)
                sample = "\(no) → \(tx.prefix(28))"
            }
            sqlite3_finalize(s2)
            var out = "轨迹库 \(count) 行"
            if !sample.isEmpty { out += "｜最近 \(sample)" }
            if !lastTraceError.isEmpty { out += "｜err \(lastTraceError)" }
            return out
        }
    }

    func setTrace(orderNo: String, text value: String) {
        queue.sync {
            guard let db else { return }
            let sql = "INSERT INTO trace_summary (order_no, text, updated) VALUES (?, ?, ?) ON CONFLICT(order_no) DO UPDATE SET text = excluded.text, updated = excluded.updated;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                lastTraceError = "insert: " + String(cString: sqlite3_errmsg(db))
                return
            }
            sqlite3_bind_text(stmt, 1, orderNo, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                lastTraceError = "step: " + String(cString: sqlite3_errmsg(db))
            }
            sqlite3_finalize(stmt)
            // 顺手把订单行本身也改掉：重启后即使 overlay 没生效，卡片也是对的
            var ustmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE orders SET logistics = ? WHERE order_no = ?;", -1, &ustmt, nil) == SQLITE_OK {
                sqlite3_bind_text(ustmt, 1, value, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(ustmt, 2, orderNo, -1, SQLITE_TRANSIENT)
                sqlite3_step(ustmt)
            }
            sqlite3_finalize(ustmt)
        }
    }

    func upsert(_ orders: [Order]) {
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "BEGIN;", nil, nil, nil)

            let sql = """
            INSERT INTO orders (id, platform, order_no, title, shop, amount, status, status_raw, order_time, logistics, pickup_code, carrier, image_url, goods_id, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title,
                shop=excluded.shop,
                amount=excluded.amount,
                status=excluded.status,
                status_raw=excluded.status_raw,
                order_time=excluded.order_time,
                logistics=excluded.logistics,
                pickup_code=excluded.pickup_code,
                carrier=excluded.carrier,
                image_url=excluded.image_url,
                goods_id=excluded.goods_id,
                updated_at=excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("[store] prepare failed")
                sqlite3_exec(db, "COMMIT;", nil, nil, nil)
                return
            }

            for o in orders {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(stmt, 1, o.id)
                bind(stmt, 2, o.platform.rawValue)
                bind(stmt, 3, o.orderNo)
                bind(stmt, 4, o.title)
                bind(stmt, 5, o.shopName)
                bind(stmt, 6, o.amount)
                bind(stmt, 7, o.status.rawValue)
                bind(stmt, 8, o.statusRaw)
                bind(stmt, 9, o.orderTime)
                bind(stmt, 10, o.logistics)
                bind(stmt, 11, o.pickupCode)
                bind(stmt, 12, o.carrier)
                bind(stmt, 13, o.imageURL)
                bind(stmt, 14, o.goodsID)
                sqlite3_bind_double(stmt, 15, o.updatedAt.timeIntervalSince1970)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("[store] step failed: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(stmt)
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }

    func all() -> [Order] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT id, platform, order_no, title, shop, amount, status, status_raw, order_time, logistics, pickup_code, carrier, image_url, goods_id, updated_at
            FROM orders ORDER BY updated_at DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var result: [Order] = []
            var traces: [String: String] = [:]
            var tstmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT order_no, text FROM trace_summary;", -1, &tstmt, nil) == SQLITE_OK {
                while sqlite3_step(tstmt) == SQLITE_ROW {
                    traces[text(tstmt, 0)] = text(tstmt, 1)
                }
            }
            sqlite3_finalize(tstmt)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = text(stmt, 0)
                let platformRaw = text(stmt, 1)
                result.append(
                    Order(
                        id: id,
                        platform: Platform(rawValue: platformRaw) ?? .pdd,
                        orderNo: text(stmt, 2),
                        title: text(stmt, 3),
                        shopName: text(stmt, 4),
                        amount: text(stmt, 5),
                        status: OrderStatus(rawValue: text(stmt, 6)) ?? .unknown,
                        statusRaw: text(stmt, 7),
                        orderTime: text(stmt, 8),
                        logistics: text(stmt, 9),
                        pickupCode: text(stmt, 10),
                        carrier: text(stmt, 11),
                        imageURL: text(stmt, 12),
                        goodsID: text(stmt, 13),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
                    )
                )
            }
            sqlite3_finalize(stmt)
            if !traces.isEmpty {
                for i in result.indices {
                    if let t = traces[result[i].orderNo], !t.isEmpty { result[i].logistics = t }
                }
            }
            return result
        }
    }

    func deleteAll() {
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "DELETE FROM orders;", nil, nil, nil)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }
}
