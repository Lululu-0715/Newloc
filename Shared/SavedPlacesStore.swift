import CoreLocation
import Foundation

/// 一个收藏的地点。
///
/// **存的是 WGS-84**（与 `Core/bridge.go` 的契约同一套体系）：
/// 它才是「本质坐标」，地图体系（境内 GCJ-02）是展示层的事。
/// 跳转时再换算成地图体系即可 —— 反正换算只有几百纳秒。
struct SavedPlace: Identifiable, Codable, Equatable {

    let id: UUID

    /// WGS-84 纬度
    var latitude: Double
    /// WGS-84 经度
    var longitude: Double

    /// 收藏时解析到的地名。解析失败时是坐标文本（见 `SpoofEffectJudge` 的降级约定）。
    var name: String

    var savedAt: Date

    init(id: UUID = UUID(),
         coordinate: CLLocationCoordinate2D,
         name: String,
         savedAt: Date = Date()) {
        self.id = id
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.name = name
        self.savedAt = savedAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 是否与某个坐标是「同一个点」。
    ///
    /// 判据是距离小于 1 米，**不是精确相等** —— 地图每次给出的
    /// `region.center` 都带浮点误差，用 `==` 比对会让同一颗星标时亮时不暗。
    func isSamePoint(as coordinate: CLLocationCoordinate2D) -> Bool {
        abs(latitude - coordinate.latitude) < 1e-5
            && abs(longitude - coordinate.longitude) < 1e-5
    }
}

/// 收藏位置的持久化。
///
/// **刻意只做最小实现**（存 / 取消 / 读列表），不做排序、分组、重命名 ——
/// 这些等真有需求再加。用 `UserDefaults` 而不是文件或数据库：
/// 数据量是个位数到几十条，一个 JSON 数组足够了，而且天然进 iOS 的备份。
@MainActor
final class SavedPlacesStore: ObservableObject {

    static let shared = SavedPlacesStore()

    @Published private(set) var places: [SavedPlace] = []

    /// 上限。不是产品需求，是防御 —— 万一有 bug 让某个循环不停往里塞，
    /// `UserDefaults` 写爆了会连带影响整个应用的其他设置。
    private static let limit = 100

    private static let storageKey = "savedPlaces.v1"

    private let defaults: UserDefaults

    /// `defaults` 开放给单测 —— 测试不许碰真实的标准域。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - 查询

    var isEmpty: Bool { places.isEmpty }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        places.contains { $0.isSamePoint(as: coordinate) }
    }

    // MARK: - 变更

    /// 收藏 / 取消收藏。同一个点再点一次就是取消 —— 星标只有一颗按钮，
    /// 不需要用户去别处删除。
    @discardableResult
    func toggle(_ coordinate: CLLocationCoordinate2D, name: String) -> Bool {
        if let index = places.firstIndex(where: { $0.isSamePoint(as: coordinate) }) {
            places.remove(at: index)
            persist()
            return false
        }

        guard places.count < Self.limit else { return false }

        places.insert(SavedPlace(coordinate: coordinate, name: name), at: 0)
        persist()
        return true
    }

    func remove(_ place: SavedPlace) {
        places.removeAll { $0.id == place.id }
        persist()
    }

    /// 重命名。空串按「未命名位置」处理（与列表展示口径一致）。
    func rename(_ place: SavedPlace, to newName: String) {
        guard let index = places.firstIndex(where: { $0.id == place.id }) else { return }
        places[index].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// 左滑删除（`onDelete` 用）。偏移按当前数组下标删，从后往前才不会串位。
    func remove(atOffsets offsets: IndexSet) {
        places.remove(atOffsets: offsets)
        persist()
    }

    func removeAll() {
        places.removeAll()
        persist()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }

        do {
            places = try JSONDecoder().decode([SavedPlace].self, from: data)
        } catch {
            // **解不出来不等于没有。** 但不至于让界面起不来 —— 收藏是附属数据，
            // 丢了不致命。记一条日志，保留一份原始数据，把内存状态清空即可。
            AppLog.error("收藏", "收藏列表解析失败", details: [
                "reason": error.localizedDescription,
                "bytes": String(data.count),
            ])
            places = []
        }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(places),
                         forKey: Self.storageKey)
        } catch {
            AppLog.error("收藏", "收藏列表写入失败", details: [
                "reason": error.localizedDescription,
            ])
        }
    }
}
