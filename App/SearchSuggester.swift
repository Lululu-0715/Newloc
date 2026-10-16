import MapKit
import SwiftUI

/// 搜索候选：输入即提示（2026-10-12 用户要求「搜索后下滑可以选择」）。
///
/// 包装系统 `MKLocalSearchCompleter` —— 地图 App 搜索框同款建议源：
/// 输入片段 → 候选地名（标题 + 区域副标题）。点选后再用
/// `MKLocalSearch(completion:)` 换取真实坐标。
@MainActor
final class SearchSuggester: NSObject, ObservableObject {

    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // 默认 resultTypes 含 .query（搜索词）与 .pointOfInterest（地名），
        // 与地图 App 的候选口径一致，不另作过滤。
    }

    /// 输入变化时调用。短于 2 个字符就清空（单字符候选噪音太大）。
    func update(query: String, region: MKCoordinateRegion?) {
        let fragment = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fragment.count >= 2 else {
            suggestions = []
            completer.queryFragment = ""
            return
        }
        if let region { completer.region = region }
        completer.queryFragment = fragment
    }

    func clear() {
        suggestions = []
        completer.queryFragment = ""
    }
}

nonisolated extension SearchSuggester: MKLocalSearchCompleterDelegate {

    /// 候选更新。completer 在主线程回调，但协议签名是非隔离的，
    /// 必须经 Task 跳回 MainActor 才能碰 @Published。
    func completer(_ completer: MKLocalSearchCompleter,
                   didUpdateResults results: [MKLocalSearchCompletion]) {
        Task { @MainActor in
            self.suggestions = results
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // 候选失败不算错 —— 列表空着就行，不打扰用户。
        Task { @MainActor in
            self.suggestions = []
        }
    }
}
