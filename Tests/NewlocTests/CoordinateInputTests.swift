import CoreLocation
import XCTest

@testable import Newloc

/// 经纬度输入解析。搜索框是这批功能里唯一能让用户「手打坐标」的入口，
/// 解析错了地图就飞到海里，所以范围与分隔符都要钉死。
final class CoordinateInputTests: XCTestCase {

    // MARK: - 能解析的写法

    func testParsesCommaSeparated() {
        let parsed = CoordinateInput.parse("39.9042, 116.4074")
        XCTAssertEqual(parsed?.latitude ?? 0, 39.9042, accuracy: 1e-9)
        XCTAssertEqual(parsed?.longitude ?? 0, 116.4074, accuracy: 1e-9)
    }

    func testParsesChineseComma() {
        let parsed = CoordinateInput.parse("39.9042，116.4074")
        XCTAssertNotNil(parsed, "中文逗号是国内输入的高频写法，必须支持")
    }

    func testParsesSpaceSeparated() {
        XCTAssertNotNil(CoordinateInput.parse("39.9042 116.4074"))
    }

    func testParsesWithoutSpace() {
        XCTAssertNotNil(CoordinateInput.parse("39.9042,116.4074"))
    }

    func testParsesNegativeCoordinates() {
        let parsed = CoordinateInput.parse("-33.86, -151.20")  // 悉尼
        XCTAssertEqual(parsed?.latitude ?? 0, -33.86, accuracy: 1e-9)
        XCTAssertEqual(parsed?.longitude ?? 0, -151.20, accuracy: 1e-9)
    }

    func testParsesBoundaryValues() {
        XCTAssertNotNil(CoordinateInput.parse("90, 180"))
        XCTAssertNotNil(CoordinateInput.parse("-90, -180"))
    }

    // MARK: - 必须拒绝的输入

    func testRejectsPlaceName() {
        XCTAssertNil(CoordinateInput.parse("北京国贸"))
    }

    func testRejectsSingleNumber() {
        XCTAssertNil(CoordinateInput.parse("39.9042"))
    }

    func testRejectsOutOfRangeLatitude() {
        // 91 超出纬度范围 —— 这种输入更像两个无关数字，不该解析。
        XCTAssertNil(CoordinateInput.parse("91, 116"))
    }

    func testRejectsOutOfRangeLongitude() {
        XCTAssertNil(CoordinateInput.parse("39, 181"))
    }

    func testRejectsNonNumeric() {
        XCTAssertNil(CoordinateInput.parse("abc, def"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(CoordinateInput.parse("   "))
    }

    // MARK: - 体系标签

    func testSystemLabelsAreStable() {
        // 开关文案直接印在界面上，改了会破版式。
        XCTAssertEqual(CoordinateInput.System.wgs84.label, "WGS-84")
        XCTAssertEqual(CoordinateInput.System.gcj02.label, "GCJ-02")
    }
}
