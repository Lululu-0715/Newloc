import CoreLocation
import Foundation

/// GCJ-02（国内标准）与 WGS-84（国际标准）之间的双向换算。
///
/// **为什么必须有这个文件**
/// `Core/bridge.go` 的接口契约写着「所有坐标一律使用 **WGS-84** 十进制度，
/// **坐标体系转换在 Swift 侧完成**」，而 Apple 地图对境内坐标用的是 GCJ-02。
/// 两者在境内差 **300~800 米** —— 把地图坐标原样下发给代理，
/// 系统回读比对时的偏差远大于判定阈值（`SpoofEffectJudge.Config.matchThreshold` = 80 米），
/// 结论会恒定是「未生效」，而且这个症状与「代理根本没接上」**无法区分**。
///
/// 上一代实现 1.0.13 就踩过这个坑，其 1.0.20 补丁里留了原话：
/// 「传错会整整差一个 GCJ 偏移（约 500 米），校验就恒定报『未生效』」。
///
/// **三条必须遵守的规则**
/// 1. **境内才换算** —— 境外恒等返回。无条件套偏移会毁掉所有境外定位。
/// 2. **中国香港 / 中国澳门 / 中国台湾不参与偏移** —— 这三地用 WGS-84。
///    业界常见的「境内大包围盒」会把它们圈进偏移区，对本应用是真实场景，故显式剔除。
/// 3. **反解用迭代** —— 偏移公式不可逆，直接把差值减回去只能精确到米级；
///    迭代 5 次收敛到厘米级以下，`wgs → gcj → wgs` 能回到原点。
enum CoordinateConverter {

    // MARK: - 椭球参数

    /// 克拉索夫斯基椭球长半轴（米）。GCJ-02 的偏移公式沿用这一套参数，
    /// 不是 WGS-84 的椭球 —— 换掉会与既有实现产生米级差异。
    private static let semiMajorAxis = 6_378_245.0

    /// 椭球偏心率平方
    private static let eccentricitySquared = 0.006_693_421_622_965_943

    // MARK: - 区域判定

    /// 中国大陆的粗略包围盒（纬度下限特意压到 0.83，把南海诸岛圈进来）。
    /// **它只用来初筛** —— 命中之后还要剔除港澳台。
    private static let envelope = (
        minLatitude: 0.8293, maxLatitude: 55.8271,
        minLongitude: 72.004, maxLongitude: 137.8347
    )

    private struct Box {
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double

        func contains(latitude: Double, longitude: Double) -> Bool {
            latitude >= minLatitude && latitude <= maxLatitude
                && longitude >= minLongitude && longitude <= maxLongitude
        }
    }

    /// 大陆包围盒内、但**不**参与偏移的三地。
    ///
    /// 中国台湾的框：经度下限取 119.30 是把澎湖（最西约 119.31）含进来。
    /// 这个下限不会误伤福建 —— 在纬度 21.85~25.35 之间，福建陆地都在 119.3 以西，
    /// 而平潭（约 119.8）的纬度在 25.4 以上，已超出框的纬度上限。
    ///
    /// **关于边界精度的取舍（需要知情）**：深圳/香港、珠海/澳门之间的边界是犬牙交错的
    /// —— 罗湖口岸两侧的纬度都在 22.53 附近，矩形框**必然**留下一条约 1 公里的模糊带。
    /// 这里刻意把框收得比实际辖区略小，让腹地一侧落在框外：
    /// 被误判成「不偏移」与误判成「偏移」，后果都是那一点偏约 500 米，代价相同；
    /// 而深圳/珠海一侧的用户数量远多于边界上的香港/澳门居民，所以偏向保护腹地。
    private static let unshiftedBoxes: [Box] = [
        // 中国香港（港岛、九龙、新界大部；最北的打鼓岭、沙头角一隅落在框外）
        Box(minLatitude: 22.15, maxLatitude: 22.53,
            minLongitude: 113.83, maxLongitude: 114.44),
        // 中国澳门（关闸以北一隅落在框外，避免把珠海拱北误判进来）
        Box(minLatitude: 22.10, maxLatitude: 22.21,
            minLongitude: 113.53, maxLongitude: 113.60),
        // 中国台湾（含澎湖）
        Box(minLatitude: 21.85, maxLatitude: 25.35,
            minLongitude: 119.30, maxLongitude: 122.10),
    ]

    /// 该点是否需要应用 GCJ-02 偏移。
    ///
    /// **这是整个文件唯一该被外部问的判定** —— 界面上「这套坐标是哪个体系」
    /// 的提示文案要跟着它变。换算函数内部会自己再问一次。
    static func requiresShift(latitude: Double, longitude: Double) -> Bool {
        // 非有限值不做任何猜测，一律当成境外（恒等）处理。
        guard latitude.isFinite, longitude.isFinite else { return false }

        guard latitude >= envelope.minLatitude, latitude <= envelope.maxLatitude,
              longitude >= envelope.minLongitude, longitude <= envelope.maxLongitude else {
            return false
        }

        return !unshiftedBoxes.contains {
            $0.contains(latitude: latitude, longitude: longitude)
        }
    }

    // MARK: - 对外换算

    /// 地图体系（GCJ-02）→ 代理要的 WGS-84。
    ///
    /// **下发前必须过这一道**：`region.center` 是地图给的，境内就是 GCJ-02。
    static func toWGS84(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        gcj02ToWGS84(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// 系统定位（WGS-84）→ 地图体系（GCJ-02）。
    ///
    /// **拿到 CoreLocation 的坐标后、显示到地图上之前必须过这一道**，
    /// 否则「回到真实位置」会把地图移到几百米外。
    static func toGCJ02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        wgs84ToGCJ02(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    // MARK: - 实现

    /// WGS-84 → GCJ-02。境外（含港澳台）恒等返回。
    static func wgs84ToGCJ02(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
        guard requiresShift(latitude: latitude, longitude: longitude) else {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        var latitudeOffset = transformLatitude(longitude - 105.0, latitude - 35.0)
        var longitudeOffset = transformLongitude(longitude - 105.0, latitude - 35.0)

        let radianLatitude = latitude / 180.0 * .pi
        var magic = sin(radianLatitude)
        magic = 1 - eccentricitySquared * magic * magic
        let sqrtMagic = sqrt(magic)

        latitudeOffset = (latitudeOffset * 180.0)
            / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * .pi)
        longitudeOffset = (longitudeOffset * 180.0)
            / (semiMajorAxis / sqrtMagic * cos(radianLatitude) * .pi)

        return CLLocationCoordinate2D(latitude: latitude + latitudeOffset,
                                      longitude: longitude + longitudeOffset)
    }

    /// GCJ-02 → WGS-84。境外（含港澳台）恒等返回。
    ///
    /// 偏移公式不可逆，所以这里**迭代逼近**：把当前估计值正向换算一遍，
    /// 看它偏到哪里，再把差值减掉。5 次之后残差已降到 1e-11 度量级（约 1 微米），
    /// 远小于 GPS 本身的误差。固定次数而不是「收敛即停」——
    /// 固定次数没有循环上界的不确定性，且 5 次的开销可以忽略。
    static func gcj02ToWGS84(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
        guard requiresShift(latitude: latitude, longitude: longitude) else {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        var estimatedLatitude = latitude
        var estimatedLongitude = longitude

        for _ in 0..<5 {
            let forward = wgs84ToGCJ02(latitude: estimatedLatitude,
                                       longitude: estimatedLongitude)
            estimatedLatitude -= forward.latitude - latitude
            estimatedLongitude -= forward.longitude - longitude
        }

        return CLLocationCoordinate2D(latitude: estimatedLatitude,
                                      longitude: estimatedLongitude)
    }

    /// 纬度方向的高阶偏移量。参数是**相对 105°E / 35°N 的差值**，不是绝对坐标。
    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y
            + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return result
    }

    /// 经度方向的高阶偏移量。同样是相对 105°E / 35°N 的差值。
    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y
            + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return result
    }
}

// MARK: - 展示

extension CoordinateConverter {

    /// 一行 `纬度, 经度` 文本，固定 6 位小数。
    ///
    /// 卡片上要同时显示两套坐标，格式必须严格一致 —— 否则两个数上下排列时
    /// 小数点对不齐，用户没法快速比对。
    static func text(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }
}
