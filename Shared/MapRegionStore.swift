import MapKit

/// 地图视野的持久化：冷启动回到上次的视野，而不是每次都落回北京。
///
/// 存中心与跨度四个 Double，**用 `object(forKey:)` 判存不存在** ——
/// `double(forKey:)` 缺键返回 0，直接用会把没存过当成「经纬度 0」（几内亚湾）。
enum MapRegionStore {

    private enum Key {
        static let latitude = "mapRegion.centerLatitude"
        static let longitude = "mapRegion.centerLongitude"
        static let latitudeDelta = "mapRegion.spanLatitudeDelta"
        static let longitudeDelta = "mapRegion.spanLongitudeDelta"
    }

    /// 冷启动读盘缓存。
    ///
    /// `persisted()` 被主视图的 `@State` 初始化器调用 —— SwiftUI 视图是
    /// struct，每次重建都会重跑初始化表达式。不缓存的话每次都要敲 4 次
    /// UserDefaults（2026-10-13 性能审查）。进程内视野由 `save` 持续落盘，
    /// 缓存只在冷启动那一刻有意义，所以读一次就够。
    private static var coldCache: MKCoordinateRegion?

    /// 盘里存过的视野。没存过返回 nil。
    ///
    /// 缓存只对 App 的 standard defaults 生效；测试注入的自定义 suite
    /// 走原路直读（否则前一个测试的空结果会污染冷缓存）。
    static func persisted(defaults: UserDefaults = .standard) -> MKCoordinateRegion? {
        let cacheable = defaults === UserDefaults.standard
        if cacheable, let coldCache { return coldCache }
        guard defaults.object(forKey: Key.latitude) != nil,
              defaults.object(forKey: Key.longitude) != nil else {
            return nil
        }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: defaults.double(forKey: Key.latitude),
                longitude: defaults.double(forKey: Key.longitude)
            ),
            span: MKCoordinateSpan(
                latitudeDelta: defaults.double(forKey: Key.latitudeDelta),
                longitudeDelta: defaults.double(forKey: Key.longitudeDelta)
            )
        )
        if cacheable { coldCache = region }
        return region
    }

    /// 视野停稳后调用（跟地名解析同一个触发点）。
    static func save(_ region: MKCoordinateRegion, defaults: UserDefaults = .standard) {
        defaults.set(region.center.latitude, forKey: Key.latitude)
        defaults.set(region.center.longitude, forKey: Key.longitude)
        defaults.set(region.span.latitudeDelta, forKey: Key.latitudeDelta)
        defaults.set(region.span.longitudeDelta, forKey: Key.longitudeDelta)
    }
}
