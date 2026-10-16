import XCTest
@testable import Newloc

/// 同心圆角尺寸链的单测。
///
/// 这里测的是**纯数学**（机型表、同心推导）；`_displayCornerRadius` 的
/// KVC 读取依赖真机/模拟器，不在单测范围。兜底表漏一行，就是
/// 重演一次「16 Pro Max 不同心」的 bug —— 所以主力机型一个都不许漏。
final class ScreenCornerRadiusTests: XCTestCase {

    // MARK: - 机型表

    func testKnownRadiiCoverMainGenerations() {
        // 每一代至少有一台代表机型在表里。
        let representatives: [(String, String)] = [
            ("iPhone11,2", "Xs"),          // 39
            ("iPhone11,8", "XR"),          // 41.5
            ("iPhone13,1", "12 mini"),     // 44
            ("iPhone13,2", "12/13"),       // 47.33
            ("iPhone13,4", "12 Pro Max"),  // 53.33
            ("iPhone15,2", "14 Pro/15"),   // 55
            ("iPhone17,2", "16 Pro Max"),  // 62
        ]
        for (identifier, name) in representatives {
            XCTAssertNotNil(ScreenCornerRadius.tableRadius(for: identifier),
                            "机型表缺 \(name)（\(identifier)）—— 那台机器会退到 fallback，同心圆角就错了")
        }
    }

    func testTableValuesMatchPublishedRadii() {
        XCTAssertEqual(ScreenCornerRadius.tableRadius(for: "iPhone17,2"), 62)
        XCTAssertEqual(ScreenCornerRadius.tableRadius(for: "iPhone15,2"), 55)
        XCTAssertEqual(ScreenCornerRadius.tableRadius(for: "iPhone10,3"), 39)
        XCTAssertNil(ScreenCornerRadius.tableRadius(for: "iSimulator,x86_64"),
                     "模拟器标识不该命中机型表（走 fallback 是预期行为）")
    }

    // MARK: - 同心尺寸链

    func testCardRadiusIsScreenRadiusMinusEdgeInset() {
        // 完整复刻上一代实现：卡片与屏幕**同心**（用户嫌「卡片和手机圆角没了」后拍板）。
        // 边距不写死数值 —— 取真源，这样改 `Tokens.Spacing.floating`
        // （8 → 12）时这条测的是「公式还对」而不是「数字没变」。
        XCTAssertEqual(PanelMetrics.cardRadius,
                       ScreenCornerRadius.value - Tokens.Spacing.floating)
    }

    /// 边距只有**一个**真源。
    ///
    /// 2026-10-14 之前 `Tokens.Spacing.floating` 与 `PanelMetrics.edgeInset`
    /// 各写一个 8 —— 改一处漏一处就会出现「卡片贴边了、圆角还是老间距算的」
    /// 那种隐形错位。这条测试把这个坑钉死。
    func testEdgeInsetHasSingleSourceOfTruth() {
        XCTAssertEqual(PanelMetrics.edgeInset, Tokens.Spacing.floating)
    }

    func testInnerRadiusIsConcentricWithCard() {
        // 同心的定义：内层圆角 = 卡片圆角 − 内容留边。
        XCTAssertEqual(PanelMetrics.innerRadius,
                       PanelMetrics.cardRadius - PanelMetrics.contentInset)
    }

    func testContentInsetFollowsTangencyFormula() {
        // 上一代原版公式：留边 = 卡片圆角 − 按钮半高（下限 20）。
        // 内层圆角正好半高 23，与卡片两条弧相切 —— 用户两轮反复后确认
        // 「同心观感优先，接受留边 24~31」，不许再改回固定值。
        XCTAssertEqual(PanelMetrics.contentInset,
                       max(PanelMetrics.cardRadius - PanelMetrics.buttonHeight / 2, 20))
    }

    func testButtonArcIsTangentWithCardArc() {
        // 正常机型（屏幕圆角 ≥ 43）：内层圆角必须正好等于按钮半高 —— 相切。
        // 只有走 20 下限分支的老机型才允许偏差（可读性 > 同心）。
        if PanelMetrics.contentInset > 20 {
            XCTAssertEqual(PanelMetrics.innerRadius, PanelMetrics.buttonHeight / 2)
            XCTAssertEqual(PanelMetrics.buttonRadius, PanelMetrics.innerRadius)
        }
    }

    func testInnerRadiusNeverExceedsButtonHalfHeight() {
        // 主按钮圆角不能超过半高（超过会被系统夹回胶囊），
        // 超出时停在半高 —— 同心让位给可读性。
        XCTAssertLessThanOrEqual(PanelMetrics.buttonRadius,
                                 PanelMetrics.buttonHeight / 2)
        XCTAssertGreaterThan(PanelMetrics.buttonRadius, 0)
        XCTAssertGreaterThan(PanelMetrics.innerRadius, 0)
    }

    func testButtonRadiusCapsAtHalfHeight() {
        // 老机型走 20 下限分支时 innerRadius 可能超过半高，此时停在半高（胶囊）。
        XCTAssertEqual(PanelMetrics.buttonRadius,
                       min(PanelMetrics.innerRadius, PanelMetrics.buttonHeight / 2))
        XCTAssertLessThanOrEqual(PanelMetrics.buttonRadius,
                                 PanelMetrics.buttonHeight / 2)
    }
}
