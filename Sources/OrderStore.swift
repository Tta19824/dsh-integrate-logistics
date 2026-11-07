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
            image_url TEXT,
            updated_at REAL
        );
        """
        sqlite3_exec(db, "ALTER TABLE orders ADD COLUMN image_url TEXT;", nil, nil, nil)
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[store] create table failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func upsert(_ orders: [Order]) {
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "BEGIN;", nil, nil, nil)

            let sql = """
            INSERT INTO orders (id, platform, order_no, title, shop, amount, status, status_raw, order_time, logistics, pickup_code, image_url, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title,
                shop=excluded.shop,
                amount=excluded.amount,
                status=excluded.status,
                status_raw=excluded.status_raw,
                order_time=excluded.order_time,
                logistics=excluded.logistics,
                pickup_code=excluded.pickup_code,
                image_url=excluded.image_url,
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
                bind(stmt, 12, o.imageURL)
                sqlite3_bind_double(stmt, 13, o.updatedAt.timeIntervalSince1970)
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
            SELECT id, platform, order_no, title, shop, amount, status, status_raw, order_time, logistics, pickup_code, image_url, updated_at
            FROM orders ORDER BY updated_at DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var result: [Order] = []
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
                        imageURL: text(stmt, 11),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
                    )
                )
            }
            sqlite3_finalize(stmt)
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
