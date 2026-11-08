import Foundation
import CoreLocation
import MapKit
import SwiftUI

struct ShipEvent: Identifiable {
    let id: Int
    let time: String
    let desc: String
}

/// 从物流接口的 JSON 里把轨迹一条条抽出来，并按时间从新到旧排。
enum ShipTracking {
    private static let descKeys = ["status_desc", "statusDesc", "desc", "info", "status_text", "statusText", "context", "content"]
    private static let timeKeys = ["status_time", "statusTime", "time", "op_time", "opTime", "create_time", "createTime", "timestamp"]
    private static let skipWords = ["预计", "请使用", "查看", "联系", "复制", "展开"]

    static func events(from data: Data) -> [ShipEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found: [(String, String)] = []
        collect(object, into: &found)
        var seen = Set<String>()
        var result: [ShipEvent] = []
        for (time, desc) in found {
            let text = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 4 else { continue }
            let key = "\(time)|\(text)"
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(ShipEvent(id: result.count, time: time, desc: text))
        }
        return result.sorted { $0.time > $1.time }
    }

    private static func collect(_ object: Any, into out: inout [(String, String)]) {
        if let dict = object as? [String: Any] {
            var desc = ""
            for key in descKeys {
                if let value = dict[key] as? String, value.count >= 4 {
                    desc = value
                    break
                }
            }
            if !desc.isEmpty {
                var time = ""
                for key in timeKeys {
                    if let value = dict[key] as? String, !value.isEmpty {
                        time = value
                        break
                    }
                    if let value = dict[key] as? Int, value > 1000000000 {
                        let date = Date(timeIntervalSince1970: Double(value))
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                        time = formatter.string(from: date)
                        break
                    }
                }
                out.append((time, desc))
            }
            for value in dict.values { collect(value, into: &out) }
        } else if let array = object as? [Any] {
            for value in array { collect(value, into: &out) }
        }
    }

    /// 轨迹里出现的城市/区县名，按出现顺序，用来在地图上顺便把路线画出来。
    /// 从整条轨迹里判断当前阶段，并抽出预计到达时间和当前城市。
    static func summary(from events: [ShipEvent]) -> (title: String, subtitle: String, stage: String, eta: String) {
        var stage = "运输中"
        var eta = ""
        var city = ""

        for event in events {
            let text = event.desc
            if stage != "已送达" {
                if containsAny(text, ["已签收", "已送达", "代收", "已投递", "已取件", "已放入"]) {
                    stage = "已送达"
                } else if stage != "派件中", containsAny(text, ["派件", "派送", "正在投递", "派送中"]) {
                    stage = "派件中"
                }
            }
            if eta.isEmpty { eta = firstMatch(text, pattern: "预计([^，。；、|]{1,8}?)送达", prefix: "预计", suffix: "送达") }
            if city.isEmpty { city = firstMatch(text, pattern: "【([^】]{2,14})】", prefix: "", suffix: "", filter: { $0.hasSuffix("市") || $0.hasSuffix("县") || $0.hasSuffix("区") }) }
        }

        let title: String
        if stage == "已送达" {
            title = "已送达"
        } else if eta.isEmpty {
            title = stage
        } else {
            title = eta
        }
        return (title, city, stage, eta)
    }

    private static func containsAny(_ text: String, _ words: [String]) -> Bool {
        for word in words where text.contains(word) { return true }
        return false
    }

    private static func firstMatch(
        _ text: String,
        pattern: String,
        prefix: String,
        suffix: String,
        filter: ((String) -> Bool)? = nil
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return "" }
        var value = (text as NSString).substring(with: match.range(at: 1))
        if let filter, !filter(value) { return "" }
        value = value.trimmingCharacters(in: .whitespaces)
        return prefix + value + suffix
    }

    /// 从物流 JSON 里找快递单号（运单号）。
    static func trackingNumber(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "" }
        let keys = ["tracking_number", "trackingNumber", "express_no", "expressNo", "mail_no", "mailNo", "waybill_no", "waybillNo", "waybill"]
        if let hit = firstString(in: object, keys: keys), hit.count >= 6 { return hit }
        let text = String(data: data, encoding: .utf8) ?? ""
        let pattern = "[A-Za-z]{0,4}[0-9]{10,20}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let ns = text as NSString
        if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: match.range)
        }
        return ""
    }

    /// 从物流 JSON 里找收件地址（用来算「还没走完的那一段」）。
    static func destination(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "" }
        let keys = ["receiver_address", "receive_address", "receiverAddress", "receiveAddress", "receiver_addr", "address", "addr"]
        if let hit = firstString(in: object, keys: keys), hit.contains("省") || hit.contains("市") { return hit }
        let text = String(data: data, encoding: .utf8) ?? ""
        let pattern = #"([\u4e00-\u9fa5]{2,8}省[^"]{4,60}|[\u4e00-\u9fa5]{2,8}市[^"]{4,60})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            return (text as NSString).substring(with: match.range)
        }
        return ""
    }

    private static func firstString(in object: Any, keys: [String]) -> String? {
        if let dict = object as? [String: Any] {
            for key in keys {
                if let value = dict[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return value
                }
            }
            for value in dict.values {
                if let hit = firstString(in: value, keys: keys) { return hit }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let hit = firstString(in: value, keys: keys) { return hit }
            }
        }
        return nil
    }

    static func placeNames(in events: [ShipEvent]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        let pattern = "【([^】]{2,14})】"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for event in events.reversed() {
            let text = event.desc
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[r])
                guard name.hasSuffix("市") || name.hasSuffix("县") || name.hasSuffix("区") else { continue }
                if seen.contains(name) { continue }
                seen.insert(name)
                names.append(name)
            }
        }
        return names
    }

    static func coordinates(for names: [String]) async -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for name in names.prefix(8) {
            let query = name.hasSuffix("市") || name.hasSuffix("县") || name.hasSuffix("区") ? name : name + "市"
            if let placemark = try? await CLGeocoder().geocodeAddressString(query).first,
               let location = placemark.location {
                result.append(location.coordinate)
            }
        }
        return result
    }
}

enum RoutePlanner {
    /// 把几个城市点连成一条「沿公路走」的线：相邻两点向 Apple 地图要驾车路线，
    /// 把每一段的折线拼起来。要不到路线就退回直线。
    static func path(through points: [CLLocationCoordinate2D]) async -> [CLLocationCoordinate2D] {
        guard points.count > 1 else { return points }
        var result: [CLLocationCoordinate2D] = []
        for index in 0..<(points.count - 1) {
            let from = points[index]
            let to = points[index + 1]
            if let leg = await drivingPath(from: from, to: to) {
                if result.isEmpty { result.append(from) }
                result.append(contentsOf: leg)
            } else {
                if result.isEmpty { result.append(from) }
                result.append(to)
            }
        }
        if result.isEmpty { return points }
        return result
    }

    private static func drivingPath(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        guard let response = try? await MKDirections(request: request).calculate() else { return nil }
        guard let route = response.routes.min(by: { $0.distance < $1.distance }) else { return nil }
        let polyline = route.polyline
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates.filter { CLLocationCoordinate2DIsValid($0) }
    }
}

struct RouteMapView: UIViewRepresentable {
    let path: [CLLocationCoordinate2D]
    let remaining: [CLLocationCoordinate2D]
    let truck: CLLocationCoordinate2D?
    let caption: String
    let subcaption: String

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // 尺寸变化（拖拽调整高度）时 SwiftUI 会不停调用这里。
        // 数据没变就什么都不做，否则每一帧都拆重建覆盖层 + 重置镜头，帧率会掉到个位数。
        let key = "\(path.count)|\(remaining.count)|\(truck?.latitude ?? 0)|\(truck?.longitude ?? 0)|\(caption)|\(subcaption)"
        if context.coordinator.lastKey == key { return }
        context.coordinator.lastKey = key

        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        context.coordinator.remainingLine = nil

        guard !path.isEmpty || !remaining.isEmpty else { return }

        if remaining.count > 1 {
            let rest = MKPolyline(coordinates: remaining, count: remaining.count)
            context.coordinator.remainingLine = rest
            mapView.addOverlay(rest)
        }

        if path.count > 1 {
            let line = MKPolyline(coordinates: path, count: path.count)
            mapView.addOverlay(line)
        }

        let box = mapView.overlays.reduce(MKMapRect.null) { partial, overlay in
            partial.union(overlay.boundingMapRect)
        }
        if !box.isNull && !box.isEmpty {
            mapView.setVisibleMapRect(
                box,
                edgePadding: UIEdgeInsets(top: 52, left: 36, bottom: 36, right: 36),
                animated: false
            )
        } else if let only = (path.first ?? remaining.first) {
            mapView.setRegion(
                MKCoordinateRegion(center: only, latitudinalMeters: 90000, longitudinalMeters: 90000),
                animated: false
            )
        }

        if let truck {
            let pin = TruckAnnotation()
            pin.coordinate = truck
            pin.title = caption
            pin.subtitle = subcaption
            mapView.addAnnotation(pin)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(caption: caption, subcaption: subcaption) }

    final class TruckAnnotation: MKPointAnnotation {
        var subtitleText = ""
    }

    /// 地图标记：上面一个绿色圆点（里面小货车），下面挂一个圆角矩形写预计时间。
    final class TruckPinView: MKAnnotationView {
        private let badge = UIView()
        private let icon = UIImageView(image: UIImage(systemName: "truck.box.fill"))
        private let box = UIView()
        private let label = UILabel()

        private let badgeSize: CGFloat = 34
        private let boxHeight: CGFloat = 26
        private let gap: CGFloat = 5

        override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            canShowCallout = false
            isEnabled = false

            badge.backgroundColor = UIColor.systemGreen
            badge.layer.cornerRadius = badgeSize / 2
            badge.layer.borderWidth = 2.5
            badge.layer.borderColor = UIColor.white.cgColor
            badge.layer.shadowColor = UIColor.black.cgColor
            badge.layer.shadowOpacity = 0.18
            badge.layer.shadowRadius = 3
            badge.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(badge)

            icon.contentMode = .scaleAspectFit
            icon.tintColor = .white
            badge.addSubview(icon)

            box.backgroundColor = UIColor.white
            box.layer.cornerRadius = 9
            box.layer.borderWidth = 1
            box.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.35).cgColor
            box.layer.shadowColor = UIColor.black.cgColor
            box.layer.shadowOpacity = 0.10
            box.layer.shadowRadius = 3
            box.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(box)

            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = UIColor.systemGreen
            label.textAlignment = .center
            label.numberOfLines = 1
            box.addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func apply(text: String) {
            label.text = text
            label.sizeToFit()

            let boxWidth = min(label.bounds.width + 18, 190)
            label.frame = CGRect(x: 9, y: (boxHeight - label.bounds.height) / 2, width: boxWidth - 18, height: label.bounds.height)

            let width = max(boxWidth, badgeSize)
            let height = badgeSize + gap + boxHeight
            frame = CGRect(origin: frame.origin, size: CGSize(width: width, height: height))

            badge.frame = CGRect(x: (width - badgeSize) / 2, y: 0, width: badgeSize, height: badgeSize)
            icon.frame = CGRect(x: 8, y: 8, width: badgeSize - 16, height: badgeSize - 16)
            box.frame = CGRect(x: (width - boxWidth) / 2, y: badgeSize + gap, width: boxWidth, height: boxHeight)

            // 让绿色圆点的中心正好压在地理坐标上，矩形从它下方伸出来。
            centerOffset = CGPoint(x: 0, y: height / 2 - badgeSize / 2)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let caption: String
        let subcaption: String
        var remainingLine: MKPolyline?
        var lastKey: String?
        init(caption: String, subcaption: String) {
            self.caption = caption
            self.subcaption = subcaption
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            if let remaining = remainingLine, remaining === line {
                renderer.strokeColor = UIColor.systemGray.withAlphaComponent(0.55)
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineDashPattern = [6, 6]
            } else {
                renderer.strokeColor = UIColor.systemGreen
                renderer.lineWidth = 5
                renderer.lineCap = .round
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is TruckAnnotation else { return nil }
            let id = "truckPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? TruckPinView
                ?? TruckPinView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.displayPriority = .required
            view.apply(text: (annotation.title ?? nil) ?? caption)
            return view
        }
    }
}
