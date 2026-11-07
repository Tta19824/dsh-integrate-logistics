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

struct RouteMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        guard !coordinates.isEmpty else { return }
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        if coordinates.count > 1 {
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(line)
            mapView.setVisibleMapRect(
                line.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                animated: false
            )
        } else if let first = coordinates.first {
            mapView.setRegion(
                MKCoordinateRegion(center: first, latitudinalMeters: 120000, longitudinalMeters: 120000),
                animated: false
            )
        }
        for (index, coordinate) in coordinates.enumerated() {
            let pin = MKPointAnnotation()
            pin.coordinate = coordinate
            pin.title = index == coordinates.count - 1 ? "当前位置" : "途经 \(index + 1)"
            mapView.addAnnotation(pin)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor.systemGreen
                renderer.lineWidth = 4
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
