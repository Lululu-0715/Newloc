import XCTest
import SwiftUI
@testable import Newloc

/// 外观切换的契约。
///
/// 这个按钮只做一件事：在浅色和深色之间切。但它有一条硬要求 ——
/// **任何一下点击，屏幕上的明暗都必须真的变化**（点下去没反应，用户会以为按钮坏了）。
/// 而「跟随系统」这一档让判断依赖环境（系统当前是浅还是深），
/// 所以 `opposite(of:system:)` 特意做成了纯函数 —— 把系统外观当参数传进来，逻辑才测得了。
@MainActor
final class AppearanceStoreTests: XCTestCase {

    private typealias Mode = AppearanceStore.Mode

    // MARK: - 两态切换

    func testLightAlwaysTogglesToDark() {
        XCTAssertEqual(AppearanceStore.opposite(of: .light, system: .light), .dark)
        XCTAssertEqual(AppearanceStore.opposite(of: .light, system: .dark), .dark)
    }

    func testDarkAlwaysTogglesToLight() {
        XCTAssertEqual(AppearanceStore.opposite(of: .dark, system: .light), .light)
        XCTAssertEqual(AppearanceStore.opposite(of: .dark, system: .dark), .light)
    }

    func testSystemGoesToTheOppositeOfWhatIsActuallyShown() {
        // 起点是「跟随系统」时要按**实际显示**取反，
        // 否则系统本来就是浅色时，第一下点了没反应。
        XCTAssertEqual(AppearanceStore.opposite(of: .system, system: .light), .dark)
        XCTAssertEqual(AppearanceStore.opposite(of: .system, system: .dark), .light)
    }

    // MARK: - 不变量

    func testEveryTapChangesWhatTheUserSees() {
        // 硬要求：任何起点 × 任何系统外观，点一下**实际显示的明暗都必须变**。
        // 三档 × 两种系统外观，全枚举。
        for system in [ColorScheme.light, .dark] {
            for start in Mode.allCases {
                let next = AppearanceStore.opposite(of: start, system: system)
                XCTAssertNotEqual(
                    next.resolved(system: system),
                    start.resolved(system: system),
                    "从 \(start.rawValue) 出发、系统 \(system == .dark ? "深色" : "浅色") 时，"
                    + "切到 \(next.rawValue) 看不出任何变化"
                )
            }
        }
    }

    func testTapsAlternateBetweenExactlyTwoStates() {
        // 这条钉的是上一版真实翻过的车：三档循环 + 「跳过空转档」的补丁，
        // 会让用户掉进「深色 ⇄ 跟随系统」两档里，**浅色这一档再也到不了**。
        // 所以这里断言两件事：点一下必定落在明或暗（不会落到「跟随系统」），
        // 且点两下必定换边。
        for system in [ColorScheme.light, .dark] {
            for start in Mode.allCases {
                let first = AppearanceStore.opposite(of: start, system: system)
                XCTAssertTrue(first == .light || first == .dark,
                              "点一下落到了 \(first.rawValue)，应该只会是浅色或深色")

                let second = AppearanceStore.opposite(of: first, system: system)
                XCTAssertNotEqual(second, first, "点两下没有换边")
                XCTAssertTrue(second == .light || second == .dark,
                              "点两下落到了 \(second.rawValue)，应该只会是浅色或深色")
            }
        }
    }

    // MARK: - 持久化

    func testModeChangeIsPersisted() {
        let suiteName = "AppearanceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppearanceStore(defaults: defaults)
        XCTAssertEqual(store.mode, .light, "盘里没有值时应该回落「浅色」（默认外观，2026-10-12 拍板）")

        store.toggle()

        // 换一个实例读同一个盘 —— 欢迎页写的值，设置页必须读得到
        let reopened = AppearanceStore(defaults: defaults)
        XCTAssertNotEqual(reopened.mode, .light, "换实例后没读回手动选择的外观")
    }

    func testUnknownStoredValueIsRewrittenToLight() {
        let suiteName = "AppearanceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 模拟降级：盘里留着更高版本写下的、当前认不出来的值
        defaults.set("someFutureMode", forKey: "appearanceMode")

        let store = AppearanceStore(defaults: defaults)
        XCTAssertEqual(store.mode, .light)
        XCTAssertEqual(defaults.string(forKey: "appearanceMode"), Mode.light.rawValue,
                       "认不出来的值应该被回写成「浅色」，不能一直留在盘里")
    }
}
