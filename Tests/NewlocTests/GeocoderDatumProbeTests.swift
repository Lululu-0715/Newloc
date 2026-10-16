import XCTest
import CoreLocation
import MapKit
@testable import Newloc

/// 探针：CLGeocoder 在大陆的坐标基准到底是什么。
///
/// 背景（2026-10-12 用户实测）：收藏「上海环球金融中心」，跳转后主界面
/// 反解出的地名却是旁边的陆家嘴地铁站 —— 怀疑喂给反解的 WGS-84 被
/// 按 GCJ-02 解读，POI 落在约 500 米外。
///
/// 方法：用 MKLocalSearch 拿环球金融中心的**地图体系**坐标（GCJ-02），
/// 换出 WGS-84，两个坐标各自反解一次，对比哪个能解回「环球金融」。
final class GeocoderDatumProbeTests: XCTestCase {

    private func reverse(_ coordinate: CLLocationCoordinate2D) async throws -> String? {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        return placemarks.first.flatMap { PlaceNameResolver.placename(from: $0) }
    }

    func testDatumProbe() async throws {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "上海环球金融中心"
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 31.23, longitude: 121.50),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))

        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            return XCTFail("搜索无结果（网络不可用？）")
        }

        let mapCoord = item.placemark.coordinate
        let wgs = CoordinateConverter.toWGS84(mapCoord)
        print("PROBE 搜索坐标(地图体系): \(mapCoord.latitude), \(mapCoord.longitude)")
        print("PROBE 换算WGS-84:        \(wgs.latitude), \(wgs.longitude)")

        let asMap = try? await reverse(mapCoord)
        let asWGS = try? await reverse(wgs)
        print("PROBE 反解[喂地图坐标]:   \(asMap ?? "nil")")
        print("PROBE 反解[喂WGS-84]:    \(asWGS ?? "nil")")

        XCTAssertNotNil(asMap ?? asWGS, "两种基准都没解出地名")
    }
}
