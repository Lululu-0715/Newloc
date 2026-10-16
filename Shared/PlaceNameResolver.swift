import CoreLocation

/// 地名解析：地图中心坐标 → 人话地名。
///
/// **为什么是 CLGeocoder**（D7 实测结论，2026-10-12）：
/// 它在部署目标 iOS 15.0 下零编译警告（弃用警告只在部署目标 ≥ 弃用版本时发），
/// 而替代品 `MKReverseGeocodingRequest` 是 iOS 26+ 独有 —— 兼容 15 就只有这一条路。
///
/// **传 WGS-84**：调用方统一传 `proxyCoordinate`，换算在这里做 ——
/// ⚠️ 2026-10-12 模拟器实测（GeocoderDatumProbeTests）：**大陆的
/// CLGeocoder 把输入坐标按 GCJ-02 解读**（Apple 地图数据库同源）。
/// 喂 WGS-84 会把 POI 反解到约 500 米外（环球金融中心 → 陆家嘴地铁站7号口，
/// 用户真机同样复现）。所以境内先转成 GCJ-02 再喂，境外（无需偏移）原样喂。
///
/// 防抖与去重都在这里做，调用方只管「停稳了就喂坐标」：
///   - 连续触发（缩放连点、程序跳转）合并成最后一次，延迟 0.6 秒；
///   - 与上次解析点相距不足 30 米就跳过 —— 省配额，地名也不会因此变。
@MainActor
final class PlaceNameResolver: ObservableObject {

    private let geocoder = CLGeocoder()

    /// 最近一次**真正发起解析**的坐标。30 米阈值靠它判断。
    private var lastResolved: CLLocationCoordinate2D?

    /// 防抖任务。新的请求会取消旧的 —— 半途的解析结果没人要了。
    private var pending: Task<Void, Never>?

    /// 解析完成。`nil` = 解析失败（断网 / 无结果），调用方保持原地名即可。
    ///
    /// ⚠️ **任何路径都必须回调**（2026-10-13 深挖修复）：此前 30 米内命中时
    /// 直接 `return`，调用方的「解析中」标记就永远等不到复位 —— 表现为
    /// 地名文字永久灰显。nil 的语义就是「没有新结果，保持原地」，
    /// 跳过时同步回调 nil 恰好是调用方想要的。
    func resolve(at coordinate: CLLocationCoordinate2D,
                 completion: @escaping (String?) -> Void) {
        // 30 米内不重解析。1e-4 度 ≈ 11 米，3 倍容差取整。
        if let lastResolved,
           abs(coordinate.latitude - lastResolved.latitude) < 3e-4,
           abs(coordinate.longitude - lastResolved.longitude) < 3e-4 {
            // 命中闸门只跳过「新的解析」，**绝不能动在飞的那一次** ——
            // 这里的 cancelGeocode 曾把刚发起的反解杀掉，两边一起丢回调。
            completion(nil)
            return
        }
        lastResolved = coordinate

        pending?.cancel()
        geocoder.cancelGeocode()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.request(coordinate, completion: completion)
        }
    }

    private func request(_ coordinate: CLLocationCoordinate2D,
                         completion: @escaping (String?) -> Void) {
        // 大陆的 CLGeocoder 按 GCJ-02 解读输入（2026-10-12 实测结论，
        // 见类注释），境内必须换过再喂；境外坐标本来就无需偏移。
        let probe = CoordinateConverter.requiresShift(latitude: coordinate.latitude,
                                                      longitude: coordinate.longitude)
            ? CoordinateConverter.toGCJ02(coordinate)
            : coordinate
        let location = CLLocation(latitude: probe.latitude,
                                  longitude: probe.longitude)
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            completion(Self.placename(from: placemarks?.first))
        }
    }

    /// 从地标拼一个「一眼能认」的地名。
    ///
    /// `name` 在国内通常是「路名 + 门牌」或 POI 名，信息量最足；
    /// 拿不到就逐级回落到区、市、省。**宁可短也不要拼一长串** —— 卡片只有一行。
    nonisolated static func placename(from placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }
        return placemark.name
            ?? placemark.subLocality
            ?? placemark.locality
            ?? placemark.administrativeArea
    }

    deinit {
        pending?.cancel()
    }
}
