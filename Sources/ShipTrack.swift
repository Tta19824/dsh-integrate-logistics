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
        let pattern = "([\u4e00-\u9fa5]{2,8}省[^\"]{4,60}|[\u4e00-\u9fa5]{2,8}市[^\"]{4,60})"
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

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
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
            mapView.addAnnotation(pin)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(caption: caption) }

    final class TruckAnnotation: MKPointAnnotation {}

    final class Coordinator: NSObject, MKMapViewDelegate {
        let caption: String
        var remainingLine: MKPolyline?
        init(caption: String) { self.caption = caption }

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
            let id = "truck"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = .systemGreen
            view.glyphImage = UIImage(systemName: "truck.box.fill")
            view.displayPriority = .required
            view.canShowCallout = true
            return view
        }
    }
}
