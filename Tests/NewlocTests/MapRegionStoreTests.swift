import CoreLocation
import MapKit
import XCTest

@testable import Newloc

/// 视野持久化。冷启动「回到上次的视野」全靠它 ——
/// 关键坑是 `double(forKey:)` 缺键返回 0，必须用 `object(forKey:)` 判存在。
final class MapRegionStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "MapRegionStoreTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEmptyDiskReturnsNil() {
        XCTAssertNil(MapRegionStore.persisted(defaults: defaults),
                     "没存过必须返回 nil —— 不能把缺键的 0 当成几内亚湾")
    }

    func testSaveThenReadRoundTrips() {
        var region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.03)
        )
        region.center.latitude = 31.2304
        MapRegionStore.save(region, defaults: defaults)

        let restored = MapRegionStore.persisted(defaults: defaults)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.center.latitude ?? 0, 31.2304, accuracy: 1e-9)
        XCTAssertEqual(restored?.center.longitude ?? 0, 121.4737, accuracy: 1e-9)
        XCTAssertEqual(restored?.span.latitudeDelta ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(restored?.span.longitudeDelta ?? 0, 0.03, accuracy: 1e-9)
    }

    func testSecondSaveOverwrites() {
        let shanghai = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        MapRegionStore.save(shanghai, defaults: defaults)

        let beijing = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        MapRegionStore.save(beijing, defaults: defaults)

        let restored = MapRegionStore.persisted(defaults: defaults)
        XCTAssertEqual(restored?.center.latitude ?? 0, 39.9042, accuracy: 1e-9)
    }
}
