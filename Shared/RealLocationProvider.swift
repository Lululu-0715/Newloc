import Combine
import CoreLocation
import Foundation

/// 读取设备当前真实位置的轻量封装。
///
/// 只服务于两件事：主界面的「实时位置」按钮，以及生效校验的回读。
/// 刻意不做持续更新与后台采集 —— 本应用的核心是把位置改掉，
/// 长期订阅真实位置既没有用处，也会平白多要一份定位权限的使用记录。
///
/// **这里拿到的是 WGS-84 原始坐标**（GPS 原始值，境内也不会被换成 GCJ-02），
/// 展示到地图上之前必须按当前地图体系换算，否则国内会偏出几百米。
@MainActor
final class RealLocationProvider: NSObject, ObservableObject {

    /// 定位失败的原因。
    ///
    /// 只做**内部分类**用，不直接展示给用户 —— 判定层把它折算成
    /// `SpoofJudge.ProbeOutcome`，文案由 `IneffectiveReason` 统一出。
    /// 所以这里不带 `errorDescription`。
    enum Failure: Error, Equatable {
        /// `authorizationStatus` 为 `.denied`。
        ///
        /// **注意**：系统「定位服务」总开关关着时，全机所有 App 都会拿到这个。
        /// 判断到底是哪一种，要另外问 `systemServicesEnabled()`。
        case denied

        /// 被家长控制 / MDM 限制。
        case restricted

        /// 暂时解算不出来（室内、刚进隧道……），下一轮再试通常就有结果。
        case unavailable(String)
    }

    @Published private(set) var isLocating = false

    /// 缓存位置的有效期（秒）。取值理由见 `requestLocationOrUseCache`。
    private static let cacheValidity: TimeInterval = 60

    private let manager = CLLocationManager()

    /// 本次请求的回调。拿到结果或失败后立即清空，保证只回调一次。
    ///
    /// 标 `@MainActor`：`CLLocationManagerDelegate` 的回调是从主队列转过来的，
    /// 而调用方（主界面）拿到坐标就要改 `@State`。不标的话调用方得自己套一层
    /// `Task { @MainActor in }`，白白多一次调度。
    private var pendingCompletion: (@MainActor (Result<CLLocationCoordinate2D, Failure>) -> Void)?

    /// 本次请求是否**绕开缓存**（见 `requestOnce(forceFresh:completion:)`）。
    private var pendingForceFresh = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// 请求一次当前位置。
    ///
    /// 未授权时会先弹系统授权框，用户同意后自动继续；拒绝则直接回调失败。
    ///
    /// - Parameter forceFresh: 为 true 时**跳过一分钟缓存**，强制向系统要一次
    ///   新解算的位置。用于「虚拟定位生效没有」这类校验：缓存里那份很可能
    ///   是改写生效**之前**的旧结果，拿它比对会得出错误的结论。
    ///   实时位置按钮不要用它 —— 那里的等待代价更显眼。
    func requestOnce(
        forceFresh: Bool = false,
        completion: @escaping @MainActor (Result<CLLocationCoordinate2D, Failure>) -> Void
    ) {
        // 上一条请求还没结束就再来一次：直接放弃旧的，以最新一次为准。
        pendingCompletion = completion
        pendingForceFresh = forceFresh
        isLocating = true

        switch manager.authorizationStatus {
        case .notDetermined:
            #if UI_TEST_HOOKS
            AppLog.info("烟测", "requestOnce.notDetermined",
                        details: ["suppressed": "\(LocationPermission.isPromptSuppressed)"])
            #endif
            // 烟测：压住授权弹窗（它会浮在整页之上，截图全废）。
            // 这里刻意**不回调也不请求** —— 回调失败会让主界面弹「定位被拒」
            // 的提示，同样盖住页面。理由与实现见 `LocationPermission`。
            guard !LocationPermission.isPromptSuppressed else { return }
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocationOrUseCache()
        case .denied:
            finish(.failure(.denied))
        case .restricted:
            finish(.failure(.restricted))
        @unknown default:
            finish(.failure(.denied))
        }
    }

    /// 有足够新的缓存就直接用，否则才真正去要一次定位。
    ///
    /// `requestLocation()` 要等 GPS 解出一次位置，室内、地下车库、刚进隧道
    /// 常常要 5–10 秒，用户看到的就是「点了半天没反应」。系统本来就维护着
    /// 一份最近位置，**一分钟内的直接采用**。
    ///
    /// 但校验路径明确要求「现取」，缓存再新也不能用：那一份多半正是改写
    /// 生效之前的旧坐标。
    private func requestLocationOrUseCache() {
        if !pendingForceFresh,
           let cached = manager.location,
           abs(cached.timestamp.timeIntervalSinceNow) < Self.cacheValidity {
            AppLog.debug("定位", "实时位置命中缓存", details: [
                "ageSeconds": String(format: "%.1f", -cached.timestamp.timeIntervalSinceNow),
            ])
            finish(.success(cached.coordinate))
            return
        }
        manager.requestLocation()
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Failure>) {
        isLocating = false
        pendingForceFresh = false
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }

    // MARK: - 系统总开关

    /// 读一次「系统定位服务总开关」。
    ///
    /// **为什么必须单独问这一项**：`authorizationStatus` 在总开关关着的时候
    /// 同样返回 `.denied`，于是「系统总开关关着」与「本应用没有授权」被压成
    /// 同一个返回值。前者用户一打开就好、后者要去设置里单独授权，处理方式
    /// 完全不同。
    ///
    /// `CLLocationManager.locationServicesEnabled()` 是**同步阻塞**的
    /// （系统要跨进程问 `locationd`），Apple 不建议在主线程调；校验是每几秒
    /// 一次的循环，卡主线程会连累整个界面，所以这里挪到后台队列再回到 async。
    nonisolated static func systemServicesEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CLLocationManager.locationServicesEnabled())
            }
        }
    }
}

extension RealLocationProvider: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.finish(.success(coordinate))
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // `kCLErrorLocationUnknown` 是「暂时定位不到」，常见于刚进入室内，
        // 多试一次通常就有结果，所以这里按 `unavailable` 处理而不是报权限问题。
        let reason = (error as NSError).localizedDescription
        Task { @MainActor in
            self.finish(.failure(.unavailable(reason)))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.handleAuthorizationChange()
        }
    }

    /// 用户响应授权后继续这次定位请求。
    ///
    /// 只有用户正等着结果时才继续，避免应用启动阶段一次无关的授权状态变化
    /// 白跑一次定位 —— 那会平白留下一条定位使用记录。
    private func handleAuthorizationChange() {
        guard pendingCompletion != nil else { return }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocationOrUseCache()
        case .denied:
            finish(.failure(.denied))
        case .restricted:
            finish(.failure(.restricted))
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}
