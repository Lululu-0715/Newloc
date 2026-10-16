import CoreLocation

/// 把搜索框里的文字解析成坐标。
///
/// 支持的写法（经纬度顺序固定：纬度在前，与卡片显示一致）：
///   - `39.9042, 116.4074`（英文逗号）
///   - `39.9042，116.4074`（中文逗号）
///   - `39.9042 116.4074`（空格分隔）
///   - `39.9042,116.4074`（无空格）
///
/// 其他文字一律返回 nil，交给 MKLocalSearch 走地名搜索。
/// 解析本身不做坐标体系换算 —— 输入是 WGS-84 还是 GCJ-02 是**用户的意图**，
/// 由界面上的开关决定（默认 WGS-84，用户拍板 2026-10-12）。
enum CoordinateInput {

    /// 输入坐标所属的体系。
    enum System: String, CaseIterable, Identifiable {
        /// GPS 原始值，境外通用，也是本工程的下发体系。
        case wgs84
        /// 国内地图体系，从国内地图 App / 网页上复制来的坐标是这个。
        case gcj02

        var id: String { rawValue }

        /// 开关上显示的短标签。
        var label: String {
            switch self {
            case .wgs84: return "WGS-84"
            case .gcj02: return "GCJ-02"
            }
        }
    }

    /// 解析成功返回经纬度；解析不出返回 nil。
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        // 全角逗号/空格统一成半角逗号，再按逗号或空白切开。
        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .trimmingCharacters(in: .whitespaces)

        let pieces = normalized
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map(String.init)

        guard pieces.count == 2,
              let latitude = Double(pieces[0]),
              let longitude = Double(pieces[1]) else {
            return nil
        }

        // 合法范围由语义决定：纬度 ±90、经度 ±180。超范围的输入不是
        // 「坐标写歪了」而是「根本不是坐标」（比如版本号 1.2 3.4），
        // 拒绝解析，别让地图飞到海里。
        guard (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
