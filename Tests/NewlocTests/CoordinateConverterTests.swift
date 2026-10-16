import CoreLocation
import XCTest

@testable import Newloc

/// `CoordinateConverter`：GCJ-02 ↔ WGS-84 双向换算。
///
/// **这里守的是 P3 第一优先的那个 bug**：Swift 侧此前从未做过坐标换算，
/// 地图给出的 GCJ-02 坐标被原样下发给只认 WGS-84 的代理，境内恒定偏约 500 米。
/// 而 500 米远大于判定阈值（`SpoofEffectJudge.Config.matchThreshold` = 80 米），
/// 于是结论恒定是「未生效」，症状与「代理根本没接上」**无法区分**。
/// 上一代实现 1.0.13 就栽在这里。
///
/// ⚠️ **本机验不了真实偏移**：模拟器不应用地区偏移，也没有真机。
/// 这一组只能保证「算法正确 + 性质成立」。**端到端必须由用户在真机确认** ——
/// 不许把这里全绿说成「已经修好了」。
final class CoordinateConverterTests: XCTestCase {

    // MARK: - 工具

    /// 两点的球面距离（米）。这里只关心量级（几百米），不必上椭球公式。
    private func distance(_ a: CLLocationCoordinate2D,
                          _ b: CLLocationCoordinate2D) -> Double {
        let earthRadius = 6_371_000.0
        let deltaLatitude = (b.latitude - a.latitude) * .pi / 180
        let deltaLongitude = (b.longitude - a.longitude) * .pi / 180
        let latitude1 = a.latitude * .pi / 180
        let latitude2 = b.latitude * .pi / 180
        let h = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
            * cos(latitude1) * cos(latitude2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// 境内取样点。**故意覆盖东南西北** —— 偏移量随地区变化，
    /// 只在华北取点会掩盖公式写错的问题。
    private let mainlandSamples: [(name: String, latitude: Double, longitude: Double)] = [
        ("北京天安门", 39.90469, 116.39134),
        ("上海人民广场", 31.23037, 121.47370),
        ("广州塔", 23.10647, 113.32459),
        ("乌鲁木齐", 43.82559, 87.61685),
        ("拉萨", 29.65200, 91.17211),
        ("哈尔滨", 45.80380, 126.53490),
        ("三亚", 18.25285, 109.51191),
    ]

    /// 境外取样点。这些地方**必须**恒等 —— 无条件套偏移会毁掉所有境外定位。
    private let overseasSamples: [(name: String, latitude: Double, longitude: Double)] = [
        ("东京", 35.68123, 139.76712),
        ("纽约", 40.75800, -73.98550),
        ("伦敦", 51.50073, -0.12463),
        ("悉尼", -33.86882, 151.20929),
    ]

    // MARK: - 往返一致

    /// 正向再反向必须回到原点。这条同时验证了「迭代反解」真的收敛 ——
    /// 如果反解只是简单地把差值减回去，这里会差出米级，直接失败。
    func testRoundTripThroughGCJ02ReturnsOrigin() {
        for sample in mainlandSamples {
            let origin = CLLocationCoordinate2D(latitude: sample.latitude,
                                                longitude: sample.longitude)
            let restored = CoordinateConverter.toWGS84(CoordinateConverter.toGCJ02(origin))

            XCTAssertEqual(restored.latitude, sample.latitude, accuracy: 1e-9,
                           "\(sample.name) 的纬度没能回到原点")
            XCTAssertEqual(restored.longitude, sample.longitude, accuracy: 1e-9,
                           "\(sample.name) 的经度没能回到原点")
        }
    }

    /// 反方向也要往返一致（界面「回到真实位置」走的是这条）。
    func testRoundTripThroughWGS84ReturnsOrigin() {
        for sample in mainlandSamples {
            let origin = CLLocationCoordinate2D(latitude: sample.latitude + 0.005,
                                                longitude: sample.longitude + 0.006)
            let restored = CoordinateConverter.toGCJ02(CoordinateConverter.toWGS84(origin))

            XCTAssertEqual(restored.latitude, origin.latitude, accuracy: 1e-9,
                           "\(sample.name) 反向往返的纬度不对")
            XCTAssertEqual(restored.longitude, origin.longitude, accuracy: 1e-9,
                           "\(sample.name) 反向往返的经度不对")
        }
    }

    // MARK: - 偏移量

    /// 内陆两套体系的偏差必须是**几百米**这个量级。
    ///
    /// 只校验量级、不锁定具体值：偏移量本来就随经纬度变化，
    /// 写死一个数只会让测试在换城市时无缘无故挂掉。
    /// 但如果换算公式抄错了（少一项、单位错、椭球参数错），
    /// 偏差会轻易掉出这个区间。
    func testOffsetMagnitudeInMainland() {
        for sample in mainlandSamples {
            let origin = CLLocationCoordinate2D(latitude: sample.latitude,
                                                longitude: sample.longitude)
            let shifted = CoordinateConverter.toGCJ02(origin)
            let offset = distance(origin, shifted)

            XCTAssertGreaterThan(offset, 150,
                                 "\(sample.name) 的偏移只有 \(offset) 米，太小了 —— 换算可能没生效")
            XCTAssertLessThan(offset, 1000,
                              "\(sample.name) 的偏移有 \(offset) 米，超出 GCJ-02 的合理量级")
        }
    }

    // MARK: - 不参与偏移的区域

    func testOverseasIsIdentity() {
        for sample in overseasSamples {
            XCTAssertFalse(
                CoordinateConverter.requiresShift(latitude: sample.latitude,
                                                  longitude: sample.longitude),
                "\(sample.name) 被误判成需要偏移"
            )

            let origin = CLLocationCoordinate2D(latitude: sample.latitude,
                                                longitude: sample.longitude)
            let shifted = CoordinateConverter.toGCJ02(origin)

            XCTAssertEqual(shifted.latitude, sample.latitude, accuracy: 1e-12,
                           "\(sample.name) 的纬度被改动了")
            XCTAssertEqual(shifted.longitude, sample.longitude, accuracy: 1e-12,
                           "\(sample.name) 的经度被改动了")
        }
    }

    /// 中国香港 / 中国澳门 / 中国台湾按境外处理，坐标必须原样保留。
    ///
    /// 业界常见的「境内大包围盒」会把这三地圈进偏移区 —— 这是本工程显式要避免的。
    func testHongKongMacaoTaiwanAreIdentity() {
        let samples: [(name: String, latitude: Double, longitude: Double)] = [
            ("中国香港·中环", 22.28190, 114.15800),
            ("中国澳门·大三巴", 22.19750, 113.54100),
            ("中国台湾·台北 101", 25.03300, 121.56500),
        ]

        for sample in samples {
            XCTAssertFalse(
                CoordinateConverter.requiresShift(latitude: sample.latitude,
                                                  longitude: sample.longitude),
                "\(sample.name) 被误判成需要偏移"
            )

            let origin = CLLocationCoordinate2D(latitude: sample.latitude,
                                                longitude: sample.longitude)
            let shifted = CoordinateConverter.toGCJ02(origin)

            XCTAssertEqual(shifted.latitude, sample.latitude, accuracy: 1e-12,
                           "\(sample.name) 的纬度被改动了")
            XCTAssertEqual(shifted.longitude, sample.longitude, accuracy: 1e-12,
                           "\(sample.name) 的经度被改动了")
        }
    }

    /// 紧邻港澳的大陆城市**必须**照常偏移 —— 边界框收窄就是为了这个。
    /// 若这里挂了，说明框放得太宽，把深圳/珠海腹地当成港澳了。
    func testMainlandCitiesNearBoundaryStillShift() {
        let samples: [(name: String, latitude: Double, longitude: Double)] = [
            ("深圳·福田", 22.54100, 114.05500),
            ("珠海·拱北", 22.21850, 113.55000),
            ("厦门", 24.47980, 118.08940),
        ]

        for sample in samples {
            XCTAssertTrue(
                CoordinateConverter.requiresShift(latitude: sample.latitude,
                                                  longitude: sample.longitude),
                "\(sample.name) 被误判成不需要偏移（边界框收得太宽）"
            )
        }
    }

    // MARK: - 交叉校验

    /// 用公开资料里的数值做一次量级交叉校验（**宽松区间，只防公式抄错**）。
    ///
    /// 天安门一带：WGS-84 约 `39.90469, 116.39134`，国内地图上显示
    /// 约 `39.90592, 116.39761`。区间给得宽是因为这些公开值本身精度有限 ——
    /// 真正严谨的端点验证要靠真机。
    func testBeijingReferenceValueFallsInExpectedRange() {
        let wgs84 = CLLocationCoordinate2D(latitude: 39.90469, longitude: 116.39134)
        let gcj02 = CoordinateConverter.toGCJ02(wgs84)

        XCTAssertTrue((39.9040...39.9075).contains(gcj02.latitude),
                      "天安门纬度换算结果是 \(gcj02.latitude)，不在预期区间")
        XCTAssertTrue((116.3940...116.4010).contains(gcj02.longitude),
                      "天安门经度换算结果是 \(gcj02.longitude)，不在预期区间")
    }

    // MARK: - 异常输入

    /// 非有限值不该被套上任何偏移 —— 否则 NaN 会传染给整条下发链路。
    func testNonFiniteInputIsLeftAlone() {
        let nan = CLLocationCoordinate2D(latitude: .nan, longitude: 116.4)
        XCTAssertTrue(CoordinateConverter.toGCJ02(nan).latitude.isNaN)
        XCTAssertFalse(CoordinateConverter.requiresShift(latitude: .nan, longitude: 116.4))

        let infinite = CLLocationCoordinate2D(latitude: 39.9, longitude: .infinity)
        XCTAssertTrue(CoordinateConverter.toGCJ02(infinite).longitude.isInfinite)
    }

    // MARK: - 展示

    /// 两行坐标要能上下对齐比对 —— 所以格式必须固定 6 位小数。
    func testTextFormatIsStable() {
        let text = CoordinateConverter.text(
            CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
        )
        XCTAssertEqual(text, "39.904200, 116.407400")
    }
}
