import MapKit
import SwiftUI

/// 主界面：地图全屏 + 顶部搜索 + 右侧浮标 + 底部悬浮卡。
///
/// **版式以 `docs/02-UI设计-黑白配色.md` 第 1.1 节为准**（用户拍板：沿用上一代版式，只换色）。
/// 改这个文件之前先回去读那一节 —— 有三处最容易走样：
///   - 右侧浮标是 **2 颗**（图层 + 实时位置），不是 3 颗；
///   - 底部卡片含**双坐标**（GCJ-02 与 WGS-84），星标在**地名旁**而不是浮标列；
///   - 边距统一 12，圆角交给系统按屏幕圆角同心。
struct MapHomeView: View {

    @StateObject private var themeStore = ThemeStore.shared
    @StateObject private var verifier = SpoofEffectVerifier.shared
    @StateObject private var proxy = ProxyController.shared
    @StateObject private var savedPlaces = SavedPlacesStore.shared
    @StateObject private var placeResolver = PlaceNameResolver()
    /// 设置 sheet 需要独立挂一份外观（sheet 的展示层不会实时跟随窗口根的
    /// `.preferredColorScheme`，不挂的话切深浅色要退出重进才生效）。
    @StateObject private var appearanceStore = AppearanceStore.shared
    @StateObject private var networkMonitor = NetworkPathMonitor.shared
    @StateObject private var suggester = SearchSuggester()

    #if THIRD_PARTY_MODE
    // 全能版独有：运行模式切换与第三方客户端控制器。
    // 普通版（不含 THIRD_PARTY_MODE 编译标志）这四行整体不存在，
    // 行为与 1.2.1 完全一致。
    @StateObject private var modeStore = ModeStore.shared
    @StateObject private var thirdParty = ThirdPartyController.shared

    /// 第三方客户端模式：改写装在用户的代理客户端里，本 App 只写坐标。
    private var isThirdPartyMode: Bool { modeStore.mode == .thirdParty }
    #else
    /// 普通版恒为内置代理模式（编译期定死，无运行时开销）。
    private var isThirdPartyMode: Bool { false }
    #endif

    /// 地图视野。**坐标系是地图体系（境内 GCJ-02）**。
    /// 冷启动读上次停稳时的视野；没存过落在北京。
    ///
    /// ⚠️ 2026-10-15 拍板：**目标点不再等于地图中心**（针钉在目标坐标上，
    /// 拖走地图时针留在原地）。拖动只改视野，不改目标 —— 改目标只有三条路：
    /// 点地图、搜索/收藏跳转、回目标点，全部收敛到 `selectTarget(onMap:)`。
    @State private var region = MapRegionStore.persisted() ?? MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.904200, longitude: 116.407400),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )

    /// 当前选中的目标点（地图体系 GCJ-02）。
    ///
    /// 冷启动取上次停稳的地图中心 —— 与旧版「目标点 = 地图中心」的
    /// 观感无缝衔接。此后它只被 `selectTarget(onMap:)` 改写；
    /// 拖地图不再动它。下发与校验都走它的 WGS-84 换算
    /// （见 `proxyCoordinate`）。
    @State private var targetCoordinate = MapRegionStore.persisted()?.center
        ?? CLLocationCoordinate2D(latitude: 39.904200, longitude: 116.407400)

    /// 地名解析的去重记号：上次解析的目标点。
    /// 拖地图不再改目标之后，`onRegionSettled` 会高频触发，
    /// 同一个目标点不重发反解请求（省配额也防闪名）。
    @State private var lastResolvedTarget: CLLocationCoordinate2D?

    /// 图层。默认标准。
    @State private var layer: MapLayerKind = .standard
    @State private var showsLayerMenu = false

    /// 真实位置，**已换算到地图体系**。nil = 还没取过。
    @State private var realLocation: CLLocationCoordinate2D?
    /// 取真实位置失败时的提示文案。
    /// 定位失败的**原始枚举**（不是文案）：alert 要按 `denied` 分支给出
    /// 「去系统设置」入口，文案在展示处用 `describe(_:)` 现算。
    @State private var locationFailure: RealLocationProvider.Failure?

    /// 反向地理编码得到的地名。
    ///
    /// nil = 还没解析出来（失败或进行中），卡片显示「未命名位置」——
    /// **绝不显示一个写死的地名**：「地图拖到上海、卡片还写着北京」
    /// 正是要杜绝的「界面在撒谎」。
    @State private var resolvedPlaceName: String?

    /// 跳转收藏时**直接显示收藏时存的地名**（2026-10-12 用户实测：
    /// 反解地名会盖掉收藏名，看起来像跳错了地方）。用户重新点地图 /
    /// 搜索 / 回实时位置时清除，之后恢复反解。
    @State private var pinnedPlaceName: String?

    /// 地名正在解析中。卡片地名以半透明呈现，暗示「这个名字还没定下来」。
    @State private var isResolvingPlaceName = false

    /// 搜索框里手打坐标按什么体系理解。默认 WGS-84（用户拍板）——
    /// 它是 GPS 原始值、也是本工程的下发体系；从国内地图复制来的才切 GCJ-02。
    @State private var inputSystem: CoordinateInput.System = .wgs84

    /// 搜索反馈（「未找到结果」等）。展示几秒自动消失。
    @State private var searchMessage: String?

    /// 搜索框聚焦态：编辑中给搜索框一圈白描边发光（全版本通用）。
    @FocusState private var searchFieldFocused: Bool

    /// 反馈消失的延时任务。新消息先把旧的取消 —— 否则连搜两次「未找到」，
    /// 第一条的 2.5 秒计时会把第二条提前清掉（2026-10-13 深挖修复）。
    @State private var searchMessageTask: Task<Void, Never>?

    /// 回车搜索的结果列表（2026-10-12 用户要求「搜索结果可选，不是直接定位」）。
    /// 坐标已是地图体系（大陆 GCJ-02），点选直接跳，不再换算。
    @State private var searchResults: [SearchHit] = []

    /// 搜索的**世代号**：每发起一次搜索自增，回调里比对，对不上就丢弃结果
    ///（2026-10-15 审查 A7）。
    ///
    /// 之前没有这道校验：`MKLocalSearch` 是临时创建、既不保存也不 cancel，
    /// `commitSearchResults` 又无条件覆盖 `searchResults`。慢网下先搜「上海」
    /// 回车、再立刻改成「北京」回车 —— 上海的响应后到，就会把结果列表盖成上海，
    /// 而搜索框里写着北京。`broadSearch` 的合并路径更糟：把两轮结果混在一起。
    @State private var searchStamp = 0

    private struct SearchHit: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String?
        let coordinate: CLLocationCoordinate2D
    }

    /// 改写生效中、但用户把地图挪离了目标点。
    /// 提示条常驻显示，直到挪回来或停止改写。
    @State private var mapMovedAway = false

    @State private var query = ""
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showManual = false
    @State private var showFavorites = false
    @State private var showConnectionSetup = false
    @State private var proxyAlert: ProxyController.Alert?
    #if THIRD_PARTY_MODE
    @State private var showModuleGuide = false
    #endif
    #if UI_TEST_HOOKS
    /// 烟测直达「运行模式」页 —— 设置页里它埋在二级导航，模拟器没有点击手段。
    @State private var showRunMode = false
    #endif

    /// 界面测试注入口的一次性闸门，避免 `onAppear` 反复触发导致页面反复弹出。
    @State private var didApplyUITestEntry = false
    @State private var didApplyAutoSpoof = false

    private let locationProvider = RealLocationProvider()

    /// 当前结论 —— 直接取校验器的，主界面不再自己维护一份。
    private var state: SpoofState { verifier.state }

    private var placeName: String {
        pinnedPlaceName ?? resolvedPlaceName ?? AppLocalization.string("未命名位置")
    }

    /// 当前选中的目标点（地图体系 GCJ-02）。**展示用**。
    private var mapCoordinate: CLLocationCoordinate2D { targetCoordinate }

    /// 代理要的 WGS-84。**下发与校验都用它。**
    ///
    /// 系统把收到的坐标当作 WGS-84 解读，而我们在地图上拿到的是 GCJ-02 ——
    /// 少了这一步换算，实际生效的位置会比用户在地图上点的那一点偏出约 500 米，
    /// 而且因为「下发值」与「回读值」仍然一致，校验还会报「已生效」，
    /// 用户只能靠第三方地图才发现自己站错了地方。
    private var proxyCoordinate: CLLocationCoordinate2D {
        CoordinateConverter.toWGS84(targetCoordinate)
    }

    /// 「选中这个点」的**唯一入口**：目标点搬过去 + 地图居中。
    ///
    /// 2026-10-15 拍板后目标点与地图中心解耦，改目标的入口全部收敛到这里
    /// —— 点地图、搜索、坐标候选、收藏、回目标点、冷启动对准改写目标、
    /// 烟测钩子。漏掉任何一条路，就会出现「针在这、实际改写在別」。
    private func selectTarget(onMap coordinate: CLLocationCoordinate2D) {
        targetCoordinate = coordinate
        region = MKCoordinateRegion(center: coordinate, span: region.span)
    }

    /// 连接设置页按运行模式分流（普通版恒为内置代理页）。
    @ViewBuilder
    private var connectionSetupSheet: some View {
        #if THIRD_PARTY_MODE
        if isThirdPartyMode {
            NavigationView { ThirdPartySetupView() }
        } else {
            NavigationView { ProxySetupView() }
        }
        #else
        NavigationView { ProxySetupView() }
        #endif
    }

    private var isCurrentPointSaved: Bool {
        savedPlaces.contains(proxyCoordinate)
    }

    var body: some View {
        ZStack(alignment: .top) {

            mapLayer

            if showsLayerMenu {
                dismissLayerMenuLayer
            }

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, Tokens.Spacing.floating)
                    .padding(.top, 6)

                Spacer(minLength: 0)

                floatingRow

                if mapMovedAway {
                    movedBanner
                        .padding(.horizontal, Tokens.Spacing.floating)
                        .padding(.bottom, 8)
                }

                bottomCard
                    .padding(.horizontal, Tokens.Spacing.floating)
                    .padding(.bottom, Tokens.Spacing.floating)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .sheet(isPresented: $showSettings) {
            // ⚠️ 外观要在这里再挂一份：sheet 是独立展示层，只靠窗口根上的
            // `.preferredColorScheme`，切深浅色时 sheet 不会实时重绘，
            // 退出重进才生效（2026-10-16 用户实测）。挂到 sheet 根上，
            // 外观 store 变化时这份 modifier 直接重算，sheet 立即换肤。
            SettingsView()
                .preferredColorScheme(appearanceStore.mode.colorScheme)
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationView { DiagnosticsView() }
        }
        .sheet(isPresented: $showManual) {
            // 烟测直达手册页；真实入口在 设置 → 关于 → 使用手册。
            NavigationView { ManualView() }
        }
        .sheet(isPresented: $showFavorites) {
            NavigationView {
                FavoritesView { place in
                    // 收藏存的是 WGS-84，上地图前换算回地图体系（境内 GCJ-02）。
                    let onMap = CoordinateConverter.toGCJ02(place.coordinate)
                    selectTarget(onMap: onMap)
                    // 地名直接用收藏时存的那个 —— 用户认的就是这个名字，
                    // 不给反解机会盖掉它。
                    pinnedPlaceName = place.name.isEmpty ? nil : place.name
                    isResolvingPlaceName = false
                }
            }
        }
        .sheet(isPresented: $showConnectionSetup, onDismiss: {
            // 从连接设置页回来：用户很可能刚配好 Wi-Fi 代理或装完证书，
            // 闸门必须立刻重算（2026-10-15 A9 的写入点之一）。
            refreshGateHint()
        }) {
            // 全能版第三方模式：连接设置整页换成模块/客户端内容，
            // 不再显示内置代理的证书与 Wi-Fi 配置（2026-10-12 用户要求）。
            connectionSetupSheet
        }
        #if UI_TEST_HOOKS
        .sheet(isPresented: $showRunMode) {
            NavigationView { RunModeSettingsView() }
        }
        #endif
        #if THIRD_PARTY_MODE
        .sheet(isPresented: $showModuleGuide) {
            NavigationView { ModuleInstallGuideView() }
        }
        .onChange(of: modeStore.mode) { _ in
            // 模式切换回来时把第三方链路状态刷新一遍，
            // 状态行不带着上一次的旧结论。
            if isThirdPartyMode { Task { await thirdParty.probe() } }
        }
        #endif
        .alert(item: $proxyAlert) { alert in
            Alert(
                title: Text(alert.failure.title),
                message: Text(alert.failure.advice),
                primaryButton: .default(Text(AppLocalization.string("去连接设置"))) {
                    showConnectionSetup = true
                },
                secondaryButton: .cancel(Text(AppLocalization.string("知道了")))
            )
        }
        .alert(AppLocalization.string("无法获取真实位置"),
               isPresented: locationAlertBinding,
               presenting: locationFailure) { failure in
            // 权限被拒 / 定位服务总开关关着（系统都报 denied）：给直达
            // 系统设置的入口 —— 否则用户只能自己摸去「设置 → 隐私」。
            if failure == .denied {
                Button(AppLocalization.string("去系统设置")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button(AppLocalization.string("知道了"), role: .cancel) { }
        } message: { failure in
            Text(Self.describe(failure))
        }
        // App 被上滑清除时代理随之消失，而 Wi-Fi 里可能还配着 127.0.0.1:8888
        // —— 用户处在全机断网的状态里。这里按上次的目标点把代理接回来。
        //
        // ⚠️ 但**第三方模式下不接**（2026-10-15 审查）：`recordTarget` 在内置与
        // 第三方两条路径**都会写盘**，所以第三方模式下盘里同样有目标点，
        // `restoreIfNeeded()` 会照样把内置代理拉起来监听 8888。而这时 Wi-Fi 代理
        // 指向的是用户自己的客户端，内置代理收不到任何流量 —— 纯空转；
        // 设置页还会显示「代理服务 · 运行中」，与「本机不跑内置代理」相反。
        // 客户端的端口若也是 8888，更会直接撞端口。
        // 第三方模式冷启动该做的事在下方的 `probe()` 分支里，与这里无关。
        .onAppear {
            // 老用户升级上来也可能还没给过权限（欢迎页那时还没有这一步）。
            LocationPermission.requestIfNeeded()
            if !isThirdPartyMode {
                proxy.restoreIfNeeded()
            }
            applyUITestEntryIfNeeded()
            applyAutoSpoofIfNeeded()

            #if THIRD_PARTY_MODE
            // 第三方模式冷启动：探一次模块，状态行不给「未检测」的旧值。
            if isThirdPartyMode, thirdParty.state == .unknown {
                Task {
                    await thirdParty.probe()
                    // 模块里还存着上次的坐标时 probe 会把状态置为 active ——
                    // 这时校验循环也要接上，理由与内置代理冷启动一致（见下）。
                    //
                    // ⚠️ 这里**不能**复用 `resumeVerificationIfPatching()`：它判的是
                    // `proxy.isPatching`，而那是**内置代理**的改写开关 —— 本模式下
                    // 已不再自动恢复内置代理（见 `onAppear` 顶部注释），冷启动时
                    // 它恒为 false，复用会让校验循环永远接不上、状态行停在「未校验」。
                    // 判据换成第三方链路自己的状态。
                    if thirdParty.state == .active, let target = proxy.lastTarget {
                        verifier.start(target: target)
                    }
                }
            }
            #endif

            // 冷启动一致性：改写还在生效时，地图必须对准**改写目标点**，
            // 而不是上次退到后台时随便停的视野 —— 否则用户看到的点和
            // 实际生效的点不是同一个。目标点也一并对齐（它是唯一入口）。
            if proxy.isPatching, let target = proxy.lastTarget {
                selectTarget(onMap: CoordinateConverter.toGCJ02(target))
            }

            // 只挪地图不够：校验器是**全新实例**（`state == .idle`），
            // 而主按钮的文案/图标只看 `state` —— 不把循环接起来，冷启动后
            // 按钮会写「开启虚拟定位」而定位其实正在被改写（2026-10-15 审查 A3）。
            resumeVerificationIfPatching()

            // 闸门缓存的首个写入点（body 里不能写状态，见 A9）。
            refreshGateHint()

            // 冷启动也解析一次地名：不该一直顶着「未命名位置」。
            // 记号同步写入 —— 不然首次停稳会重发同一笔反解。
            lastResolvedTarget = targetCoordinate
            isResolvingPlaceName = true
            placeResolver.resolve(at: proxyCoordinate) { name in
                isResolvingPlaceName = false
                if let name {
                    resolvedPlaceName = name
                } else {
                    lastResolvedTarget = nil
                }
            }
        }
        // MARK: 闸门缓存的写入点（全部在 body 之外 —— 见 A9）
        //
        // 闸门只可能因为这几件事变化：校验状态在「未开启 ↔ 已开启」之间跳、
        // 网络在 Wi-Fi / 蜂窝之间切、用户去系统设置改完代理切回来
        // （`didBecomeActive` 已经覆盖）、从连接设置页回来。都挂在这里，
        // 就不需要原来那种「读的时候顺手回写」的懒刷新了。
        .onChange(of: verifier.state) { _ in refreshGateHint() }
        .onChange(of: networkMonitor.isWiFi) { _ in refreshGateHint() }
        .onChange(of: networkMonitor.hasResult) { _ in refreshGateHint() }
        // 连接诊断是全局状态：设置页、连接设置页、诊断页都在读它。
        // 主界面是用户停留最久的地方，在这里刷一次，那几个页面拿到的就是新的。
        // ⚠️ 第三方模式跳过（2026-10-13 性能审查）：这两项检测要起临时
        // HTTPS 服务再发一次真实请求，而第三方模式既不跑内置代理、也不靠
        // 内置证书做 MITM —— 冷启动白烧一轮握手。需要时设置页/诊断页手动刷。
        .task {
            #if THIRD_PARTY_MODE
            if !isThirdPartyMode {
                await ConnectionDiagnostics.shared.refresh()
            }
            #else
            await ConnectionDiagnostics.shared.refresh()
            #endif
        }
        // 用通知而不是 `onChange(of: scenePhase)`：后者在 iOS 17 之后换了
        // 签名，用它就得写 `#available` 分支。而且这两个通知的口径更明确 ——
        // 「真的进了后台」和「真的回到了前台」两件事，`scenePhase` 里还夹着
        // 一个 `.inactive`（下拉通知中心、来电都会触发），我们不要它。
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification)) { _ in
            verifier.handleScenePhase(.background)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            // 代理要先恢复再谈校验：校验里的链路探针要问的正是「代理通不通」，
            // 顺序反了会拿到一次注定失败的证据。
            // 闸门缓存一并刷新：用户去 Wi-Fi 设置改完代理切回来，
            // 主按钮状态必须立刻如实，不能等 TTL 到期。
            refreshGateHint()
            Task {
                await proxy.recoverAfterForeground()
                verifier.handleScenePhase(.active)
            }
        }
    }

    // MARK: - 地图

    private var mapLayer: some View {
        MapLayer(
            region: $region,
            mapType: layer.mapType,
            realLocation: realLocation,
            targetPin: targetCoordinate,
            accentColor: themeStore.accent,
            pinOutlineColor: themeStore.theme.onPrimaryAction,
            onSelectCoordinate: { coordinate in
                closeLayerMenu()
                // 点地图 = 选中这个点：目标点搬过去、地图居中。
                // 「改写到哪」的唯一答案是针钉住的那个坐标。
                selectTarget(onMap: coordinate)
                pinnedPlaceName = nil
            },
            onRegionSettled: { center in
                // 视野持久化：冷启动回到这里（与地名解析同一触发点，一次手势一次）。
                // 拖动只改视野不改目标（2026-10-15 拍板）。
                MapRegionStore.save(region)
                refreshMovedBanner(center: center)

                // 停稳后解析一次地名（收藏跳转的「钉住地名」期间不解析，
                // 不让反解结果盖掉用户收藏时的名字）。解析的是**目标点**
                // 不是地图中心 —— 卡片描述的就是针钉住的那个点；
                // 同一个目标不重发（见 `lastResolvedTarget`）。换算成
                // WGS-84 再喂给 CLGeocoder —— 它的坐标契约与 GPS 一致。
                if pinnedPlaceName == nil,
                   // CLLocationCoordinate2D 不接 Equatable，用工程现成的容差比较
                   //（`MapLayer.swift` 提供，1e-6 度 ≈ 0.1 米）。
                   !(lastResolvedTarget?.isNearlyEqual(to: targetCoordinate) ?? false) {
                    lastResolvedTarget = targetCoordinate
                    isResolvingPlaceName = true
                    placeResolver.resolve(at: proxyCoordinate) { name in
                        isResolvingPlaceName = false
                        if let name {
                            resolvedPlaceName = name
                        } else {
                            // 失败了把记号退回去，下次停稳还能重试。
                            lastResolvedTarget = nil
                        }
                    }
                }
            }
        )
        // **必须放在最后**：让地图全屏铺开（不避让安全区），
        // 视野与手势的坐标系才与屏幕中心/地图中心一致。
        // （旧版选点针 overlay 也靠这一条对准屏幕中心；2026-10-15 针改
        // MKAnnotationView 后，对准坐标的事由 centerOffset 负责。）
        .ignoresSafeArea()
    }

    // MARK: - 顶部

    private var topBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.app(14, weight: .medium))
                        .foregroundStyle(Color.ncTextSecondary)

                    TextField(AppLocalization.string("搜索地点或坐标"), text: $query)
                        .font(.app(15))
                        .textFieldStyle(.plain)
                        .focused($searchFieldFocused)
                        .submitLabel(.search)
                        .onSubmit(submitSearch)
                        .onChange(of: query) { newValue in
                            // 输入即出候选（2026-10-12 用户要求「搜索后下滑可以选择」）。
                            suggester.update(query: newValue, region: region)
                            // 一旦重新打字，上次回车搜出来的结果列表就过期了。
                            searchResults = []
                        }

                    // 一键清除（2026-10-13 用户要求）：有内容才出现。
                    // 清的不只是输入框 —— 候选下拉、回车结果一并收掉。
                    if !query.isEmpty {
                        Button {
                            clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.app(14, weight: .medium))
                                .foregroundStyle(Color.ncTextTertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.string("清空搜索"))
                        .transition(.opacity)
                    }

                    // 手打坐标时才出现的体系开关：输入按哪套坐标理解。
                    // 隐藏时占位为零，不改变搜索框的布局。
                    if CoordinateInput.parse(query) != nil {
                        Button {
                            inputSystem = inputSystem == .wgs84 ? .gcj02 : .wgs84
                        } label: {
                            Text(inputSystem.label)
                                .font(.app(10, weight: .semibold).monospaced())
                                .foregroundStyle(themeStore.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(themeStore.accent.opacity(0.12))
                                )
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.string("坐标体系"))
                        .accessibilityValue(inputSystem.label)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: Tokens.Size.searchBar)
                // iOS 26 走**原生液态玻璃**（与上一代实现同构，玻璃自身
                // 对触摸有响应）；iOS 15~18 由 `GlassContainer` 自动降级成
                // 自绘（磨砂 + 滑杆染色 + 亮边）。分叉点见 `GlassContainer`。
                // 清除 X、坐标开关照旧是内容层按钮，点击直达。
                .glassContainer(cornerRadius: Tokens.Size.searchBar / 2,
                                prominent: true,
                                adjustableTint: themeStore.glassTintBase)
                .appPressFeedback()
                // 聚焦发光：编辑中一圈白描边 + 微光，所有系统版本通用。
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(searchFieldFocused ? 0.6 : 0),
                                      lineWidth: 1)
                        .shadow(color: .white.opacity(searchFieldFocused ? 0.45 : 0), radius: 6)
                        .allowsHitTesting(false)
                }
                .animation(.easeOut(duration: 0.18), value: searchFieldFocused)

                CircleIconButton(systemImage: "gearshape",
                                 diameter: Tokens.Size.searchBar) {
                    showSettings = true
                }
            }

            // 搜索候选下拉：输入即出，点一条跳一条（2026-10-12 用户要求）。
            if showSuggestions {
                suggestionList
            }

            if let searchMessage {
                Text(searchMessage)
                    .font(.app(12))
                    .foregroundStyle(Color.ncTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        // 胶囊玻璃：圆角 = 半高（文字 12 + 上下 5 → 总高 22）。
                        Capsule().glassContainer(cornerRadius: 11, nested: true)
                    )
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 搜索候选

    /// 有搜索结果、有候选或输入的是坐标时才显示下拉。
    private var showSuggestions: Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return !searchResults.isEmpty
            || !suggester.suggestions.isEmpty
            || CoordinateInput.parse(text) != nil
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            if !searchResults.isEmpty {
                // 回车搜索的结果列表：点哪条跳哪条（用户要求「结果可选」）。
                ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, hit in
                    suggestionRow(systemImage: "mappin",
                                  title: hit.title,
                                  subtitle: hit.subtitle ?? "") {
                        pick(hit)
                    }
                    if index != searchResults.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }

                // 相关地点：输入联想并进结果列表（2026-10-13 用户要求
                // 「不要局限于输入的词」—— 搜环球金融中心，北门、停车楼
                // 这类关联条目也要能直接点）。补全器本身就是模糊匹配，
                // 点一条走「补全 → 二次查询换坐标」的老路。
                if !suggester.suggestions.isEmpty {
                    relatedHeader

                    ForEach(Array(suggester.suggestions.enumerated()), id: \.offset) { index, completion in
                        suggestionRow(systemImage: "mappin.and.ellipse",
                                      title: completion.title,
                                      subtitle: completion.subtitle) {
                            pick(completion)
                        }
                        // ⚠️ 用序号当 ID，不用对象本身：SwiftUI 对「重复 ID」
                        // 在老系统上直接崩（2026-10-15 拍板的 iOS 16.3 闪退
                        // 顺手加固），序号永不重复。
                        if index != suggester.suggestions.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            } else {
                // 手打坐标永远是第一条 —— 用户输入的就是它，别的候选都靠后。
                let text = query.trimmingCharacters(in: .whitespaces)
                if let parsed = CoordinateInput.parse(text) {
                    suggestionRow(systemImage: "location.north.line",
                                  title: AppLocalization.string("跳转到坐标"),
                                  subtitle: String(format: "%.6f, %.6f", parsed.latitude, parsed.longitude)
                                      + " · " + inputSystem.label) {
                        pickCoordinate(parsed)
                    }
                    if !suggester.suggestions.isEmpty {
                        Divider().padding(.leading, 44)
                    }
                }

                ForEach(Array(suggester.suggestions.enumerated()), id: \.offset) { index, completion in
                    suggestionRow(systemImage: "mappin",
                                  title: completion.title,
                                  subtitle: completion.subtitle) {
                        pick(completion)
                    }
                    // 同上：序号当 ID，不拿对象当身份（iOS 16 重复 ID 崩溃类）。
                    if index != suggester.suggestions.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        // 圆角 14 → 20（2026-10-15 用户拍板：搜索结果列表太方）。
        .glassContainer(cornerRadius: 20, tint: themeStore.glassTint, prominent: true)
    }

    /// 「相关地点」小节标题（结果列表与联想建议之间）。
    private var relatedHeader: some View {
        Text(AppLocalization.string("相关地点"))
            .font(.app(11))
            .foregroundStyle(Color.ncTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.top, 9)
            .padding(.bottom, 3)
    }

    /// 搜索框一键清除（X 按钮）。
    private func clearSearch() {
        query = ""
        suggester.clear()
        searchResults = []
    }

    /// 点了搜索结果：坐标已是地图体系，直接选为目标。
    private func pick(_ hit: SearchHit) {
        selectTarget(onMap: hit.coordinate)
        pinnedPlaceName = nil
        finishSuggestion()
        searchResults = []
    }

    private func suggestionRow(systemImage: String,
                               title: String,
                               subtitle: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.app(13, weight: .medium))
                    .foregroundStyle(themeStore.accent)
                    .frame(width: 21)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.app(14, weight: .medium))
                        .foregroundStyle(Color.ncText)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.app(11))
                        .foregroundStyle(Color.ncTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 点了坐标候选：与 `submitSearch` 的坐标分支同一套换算。
    private func pickCoordinate(_ parsed: CLLocationCoordinate2D) {
        let onMap = inputSystem == .wgs84
            ? CoordinateConverter.toGCJ02(parsed)
            : parsed
        selectTarget(onMap: onMap)
        pinnedPlaceName = nil
        finishSuggestion()
    }

    /// 点了地名候选：系统补全只给地名不给坐标，二次查询换取。
    private func pick(_ completion: MKLocalSearchCompletion) {
        suggester.clear()

        let request = MKLocalSearch.Request(completion: completion)
        request.region = region
        MKLocalSearch(request: request).start { [self] response, _ in
            // ⚠️ MapKit 不保证回调在主线程。在后台线程改 SwiftUI 状态 /
            // 调 UIApplication，在 iOS 16 上会直接闪退（2026-10-13 用户实测
            // iOS 16.3 搜索闪退的最可疑路径）—— 一律先跳回主线程。
            DispatchQueue.main.async { [self] in
                guard let item = response?.mapItems.first else {
                    showSearchMessage(AppLocalization.string("未找到结果"))
                    return
                }
                // ⚠️ MKLocalSearch 的结果**本来就是地图体系**（大陆为 GCJ-02，
                // 与 MKMapView 渲染同源）——再换算一次就是双重偏移约 500 米
                // （2026-10-12 用户实测：搜东方明珠，钉子落在旁边）。
                let onMap = item.placemark.coordinate
                selectTarget(onMap: onMap)
                pinnedPlaceName = nil
                finishSuggestion()
            }
        }
    }

    /// 选完收下拉、清输入、收键盘 —— 让地图结果完整露出来。
    private func finishSuggestion() {
        query = ""
        suggester.clear()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    // MARK: - 右侧浮标

    /// 浮标那一行：按钮列贴右、紧贴卡片上方。
    ///
    /// 把浮标放进同一个 `VStack` 里而不是让它绝对定位，是为了不用硬编码
    /// 「距底多少」—— 卡片变高变矮时浮标会自动跟着走。
    private var floatingRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 0)

            floatingButtons
        }
        .padding(.trailing, Tokens.Spacing.floating)
        .padding(.bottom, 12)
    }

    /// 右侧浮标两颗粒。与顶部设置圆钮同为 44×44、同一套玻璃。
    ///
    /// 图层胶囊挂在按钮列头顶（`overlay` + 向上偏移）—— 用户 2026-10-14
    /// 拍板：不要向左展开，要往上弹出一个胶囊（仿上一代实现）。
    private var floatingButtons: some View {
        VStack(spacing: 10) {
            CircleIconButton(systemImage: "rectangle.stack") {
                toggleLayerMenu()
            }

            CircleIconButton(systemImage: "location") {
                moveToRealLocation()
            }
        }
        .overlay(alignment: .top) {
            if showsLayerMenu {
                layerCapsule
                    .offset(y: -(Self.layerCapsuleHeight + 10))
                    .transition(.scale(scale: 0.5, anchor: .bottom)
                        .combined(with: .opacity))
            }
        }
    }

    /// 胶囊总高（3 行 × 42 + 行距 2×2 + 上下 6×2），上弹偏移要用它。
    private static let layerCapsuleHeight: CGFloat = 3 * 42 + 2 * 2 + 12

    private func toggleLayerMenu() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            showsLayerMenu.toggle()
        }
    }

    /// 只关不开。点地图选点、点空白收起都必须用它 —— 用 toggle 的后果是
    /// 「胶囊关着时点地图 = 把它打开」（2026-10-14 真机实锤的乱开 bug）。
    private func closeLayerMenu() {
        guard showsLayerMenu else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            showsLayerMenu = false
        }
    }

    /// 图层胶囊：窄竖条、只有图标，从图层按钮正上方弹出（仿上一代实现）。
    ///
    /// 选中态 = 强调色图标 + **正圆底块**（2026-10-14 用户点名圆形选择框，
    /// 不要圆角方块）—— 黑白主题里强调色就是黑，只靠图标颜色分不出选中，
    /// 必须有一块底色兜底。
    private var layerCapsule: some View {
        VStack(spacing: 2) {
            ForEach(MapLayerKind.allCases) { kind in
                Button {
                    layer = kind
                    toggleLayerMenu()
                } label: {
                    Image(systemName: kind.systemImage)
                        .font(.app(16, weight: .medium))
                        .foregroundStyle(layer == kind ? themeStore.accent : Color.ncTextSecondary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(themeStore.accent.opacity(layer == kind ? 0.16 : 0))
                        )
                        .padding(.horizontal, 6)
                        .contentShape(Circle())
                }
                .appPressFeedback(growScale: 1.06)
                .accessibilityLabel(kind.title)
            }
        }
        .padding(.vertical, 6)
        .glassContainer(cornerRadius: 28,
                        tint: themeStore.glassTint,
                        prominent: true)
    }

    /// 图层菜单展开时那层「点别处收起」。
    ///
    /// 压在地图之上、内容之下 —— 点地图收起菜单，点浮标仍然正常生效。
    private var dismissLayerMenuLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { closeLayerMenu() }
            .ignoresSafeArea()
    }

    // MARK: - 底部卡片

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 12) {

            // 内置代理的故障条只在内置模式下显示 —— 第三方模式下没有
            // 本机代理服务，它的 failure 与本模式无关。
            if !isThirdPartyMode, let failure = proxy.failure {
                proxyWarningRow(failure)
            }

            // 选点内层小卡：地名 + 星标 + 双坐标包在一张**与外卡同心**的
            // 浅色小卡里，右侧竖排收藏夹 / 诊断两颗小圆钮 —— 上一代实现的
            // selectionCard 结构，设计稿画的也是它。
            selectionCard

            // 状态类信息摆在主按钮**上方**，主按钮压在最下面 ——
            // 它是这一屏唯一的行动点。
            statusRow

            // 环境闸门提示：非 Wi-Fi / 其他代理软件占用系统代理时，
            // 主按钮禁用，这里明说原因（2026-10-12 用户要求的两项检测）。
            if let gate = gateHint {
                gateHintRow(gate)
            }

            // 嵌在自绘玻璃卡内：实底填充（玻璃叠玻璃是 HIG 禁忌）。
            PrimaryButton(title: primaryTitle,
                          systemImage: primaryIcon,
                          isEnabled: primaryButtonEnabled,
                          cornerRadius: PanelMetrics.buttonRadius,
                          embeddedInGlass: true) {
                toggleSpoofing()
            }
        }
        // 内容留边是**算出来的**（卡片圆角 − 23），不是随手定的 ——
        // 这样主按钮的圆角正好与卡片同心。下边再与 Home 指示条(34)取大者，
        // 防止按钮被指示条压住。
        .padding(.horizontal, PanelMetrics.contentInset)
        .padding(.top, PanelMetrics.contentInset)
        .padding(.bottom, max(PanelMetrics.contentInset, 26))
        // ⚠️ 命中形状必须盖住整张卡片：不加它，卡片玻璃背景是「透明」的，
        // 空白处的触摸会穿透到下面的地图（2026-10-12 用户实测反馈）。
        // 拦下来之后，卡片内空白处点按/拖动都不再影响地图。
        .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.cardRadius,
                                       style: .continuous))
        // 上一代实现同款自绘玻璃（2026-10-14 拍板回退）：磨砂 + 滑杆染色
        // + 亮边，垫 background 不参与触摸；卡内收藏/诊断小圆钮 nested 档、
        // 主按钮实底填充，都不叠玻璃。原生 interactive 玻璃太透，已弃用。
        .glassContainer(cornerRadius: PanelMetrics.cardRadius,
                        prominent: true,
                        adjustableTint: themeStore.glassTintBase)
    }

    /// 选点内层小卡。底色 `primary.opacity(0.06)`、圆角 = 卡片圆角 − 留边
    /// （同心），右侧两颗 34pt 圆钮共同撑满左侧三行的高度。
    /// 尺寸是用户 2026-10-12 拍板的放大档：边距收窄后卡片变宽，
    /// 内容不放大就显得空。（边距沿革见 `PanelMetrics` 头注释。）
    private var selectionCard: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                // 星标紧跟地名：点地名旁边就能收藏/取消，单手操作最顺。
                HStack(spacing: 8) {
                    Text(placeName)
                        .font(.app(20, weight: .semibold))
                        .foregroundStyle(isResolvingPlaceName ? Color.ncTextTertiary : Color.ncText)
                        .lineLimit(1)

                    favoriteButton

                    Spacer(minLength: 0)
                }

                // 双坐标各带一个复制小图标：点哪行复制哪行，不再单独占一行。
                HStack(spacing: 6) {
                    Text("GCJ-02  " + CoordinateConverter.text(mapCoordinate))
                        .font(.app(13).monospaced())
                        .foregroundStyle(Color.ncTextSecondary)
                    CoordinateCopyIcon(accessibilityLabel: "GCJ-02",
                                       value: CoordinateConverter.text(mapCoordinate))
                }

                HStack(spacing: 6) {
                    Text("WGS-84  " + CoordinateConverter.text(proxyCoordinate))
                        .font(.app(13).monospaced())
                        .foregroundStyle(Color.ncTextSecondary)
                    CoordinateCopyIcon(accessibilityLabel: "WGS-84",
                                       value: CoordinateConverter.text(proxyCoordinate))
                }
            }

            VStack(spacing: 8) {
                favoritesCircle
                diagnosticsCircle
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PanelMetrics.innerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// 地名旁边的星标。上一代实现的原文是「在地图上选好点，点地名旁的星标即可收藏」——
    /// 所以它在**地名旁边**，不在右侧浮标列里。
    private var favoriteButton: some View {
        Button {
            savedPlaces.toggle(proxyCoordinate, name: placeName)
        } label: {
            Image(systemName: isCurrentPointSaved ? "star.fill" : "star")
                .font(.app(15, weight: .medium))
                .foregroundStyle(isCurrentPointSaved ? themeStore.accent : Color.ncTextTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.string(
            isCurrentPointSaved ? "取消收藏" : "收藏"
        ))
    }

    /// 收藏夹入口（内层小卡右侧，上）。图标用 bookmark，与地名旁的星标区分：
    /// 星标 = 收藏/取消当前点，书签 = 打开收藏夹列表。
    private var favoritesCircle: some View {
        Button {
            showFavorites = true
        } label: {
            Image(systemName: "bookmark.fill")
                .font(.app(14, weight: .semibold))
                // 2026-10-13 用户要求加深一档：次文字色在玻璃上看不清。
                .foregroundStyle(Color.ncText)
                .frame(width: 34, height: 34)
                .glassContainer(cornerRadius: 17, nested: true)
                .contentShape(Circle())
        }
        .appPressFeedback()
        .accessibilityLabel(AppLocalization.string("收藏位置"))
    }

    /// 诊断入口（内层小卡右侧，下）。已生效时符号变绿，与校验行同一信号。
    private var diagnosticsCircle: some View {
        Button {
            showDiagnostics = true
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.app(14, weight: .semibold))
                // 同上（2026-10-13）：非生效态也加深，只让绿点做状态区分。
                .foregroundStyle(state == .effective ? Color.green : Color.ncText)
                .frame(width: 34, height: 34)
                .glassContainer(cornerRadius: 17, nested: true)
                .contentShape(Circle())
        }
        .appPressFeedback()
        .accessibilityLabel(AppLocalization.string("运行日志与诊断"))
    }

    /// 状态行（用户拍板 2026-10-12：四颗挤一行，不再拆两行）。
    ///
    /// 左边两颗是**环境状态**（链路配好了没有）：内置代理 + 证书；
    /// 右边两颗只在虚拟定位**开着时**出现（改写生效了没有）：结论胶囊 + 重新验证。
    /// 「真的生效了」与「链路配好了」是两件事，但一行放得下就不必占两行。
    private var statusRow: some View {
        HStack(spacing: 6) {
            #if THIRD_PARTY_MODE
            if isThirdPartyMode {
                // 与内置模式对齐（用户真机反馈 2026-10-13：第三方只有一颗胶囊，
                // 看不出当前跑在哪条链路上、也无处发起验证）：
                // 左边两颗是环境状态（哪条链路 + 模块通不通），
                // 右边校验器与内置共用同一个 SpoofEffectVerifier —— 它验的是
                // 「系统有没有真的用上新位置」，跟改写发生在哪个进程无关。
                NeutralPill(text: AppLocalization.string("第三方代理"),
                            systemImage: "arrow.triangle.branch")

                modulePill

                Spacer(minLength: 8)

                if thirdParty.state == .unreachable, let error = thirdParty.lastError {
                    // 不通时把原因挤进行尾，点了模块胶囊跳安装引导。
                    Button {
                        showModuleGuide = true
                    } label: {
                        Text(error)
                            .font(.app(11))
                            .foregroundStyle(Color.ncTextSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .buttonStyle(.plain)
                } else if thirdParty.state == .active && state != .idle {
                    verificationCluster
                }
            } else {
                builtInStatusRow
            }
            #else
            builtInStatusRow
            #endif
        }
    }

    /// 内置代理模式的状态行（普通版唯一路径；全能版在第三方模式之外使用）。
    private var builtInStatusRow: some View {
        HStack(spacing: 6) {
            NeutralPill(text: AppLocalization.string("内置代理"),
                        systemImage: "wifi.router")

            certificatePill

            Spacer(minLength: 8)

            if state != .idle {
                verificationCluster
            }
        }
    }

    /// 校验结论 + 重新验证。挤进状态行后原来那句人话说明放不下了 ——
    /// 完整原因始终在诊断页，胶囊本身就是入口。
    private var verificationCluster: some View {
        HStack(spacing: 8) {
            StatusPill(text: state.text, tint: state.tint)

            Button {
                // ⚠️ 目标是**改写真正生效的点**（`proxy.lastTarget`），不是当前选点。
                // 选中一个新点（点地图/搜索）不会自动重新下发 —— 要按主按钮。
                // 用 `proxyCoordinate`（= 当前选点）去比，后果是：用户改选了
                // 别的点再点这颗刷新，就会拿新点去比对「系统回读到旧目标点」
                // → 报一次**假阴性**（「系统未刷新 / 代理没接上」），同时把
                // 校验器的目标改成新选点、与代理的实际目标分叉，后续
                // `handleScenePhase(.active)` 的续开逻辑也跟着跑偏
                //（2026-10-15 审查 A1）。
                //
                // 走到这里 `state != .idle`（`verificationCluster` 的显示条件），
                // 所以 `lastTarget` 必然存在；`?? proxyCoordinate` 只是兜底。
                verifier.start(target: proxy.lastTarget ?? proxyCoordinate)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.app(12, weight: .semibold))
                    .foregroundStyle(state == .verifying ? Color.ncTextTertiary : themeStore.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state == .verifying)
            .accessibilityLabel(AppLocalization.string("重新验证"))
        }
    }

    /// 证书胶囊：实测结论驱动（起一个临时 HTTPS 握手看信任），不是常量。
    @ViewBuilder
    private var certificatePill: some View {
        switch ConnectionDiagnostics.shared.trust {
        case .trusted:
            StatusPill(text: AppLocalization.string("证书已信任"),
                       tint: .effective,
                       systemImage: "checkmark.shield.fill")
        case .untrusted:
            StatusPill(text: AppLocalization.string("证书未信任"),
                       tint: .ineffective,
                       systemImage: "shield.slash")
        case .unavailable:
            // 「不知道」保持中性：没测成不代表没信任，不能报一个要用户动手修的状态。
            NeutralPill(text: AppLocalization.string("证书状态未知"),
                        systemImage: "shield")
        }
    }

    /// 代理起不来时的提示条。可点，直接跳到连接设置。
    private func proxyWarningRow(_ failure: ProxyController.Failure) -> some View {
        Button {
            showConnectionSetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.app(12, weight: .semibold))
                    .foregroundStyle(StatusTint.ineffective.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.title)
                        .font(.app(13, weight: .medium))
                        .foregroundStyle(Color.ncText)

                    Text(failure.advice)
                        .font(.app(11))
                        .foregroundStyle(Color.ncTextSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(Color.ncTextTertiary)
            }
            .padding(10)
            .background(
                StatusTint.ineffective.color.opacity(StatusTint.fillOpacity),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 移开提示条

    /// 改写生效中把地图挪走了：提示条常驻，防止「看着别处、改在别处」。
    ///
    /// 阈值 100 米与校验器的判定档（80 米）同量级 —— 比它宽一点，
    /// 不然校验还在报「已生效」，提示条就先弹出来了，两个信号打架。
    private static let movedBannerThreshold: CLLocationDistance = 100

    /// 挪没挪走：地图中心（换回 WGS-84）与改写目标点的实地距离说了算。
    func refreshMovedBanner(center: CLLocationCoordinate2D) {
        guard proxy.isPatching, let target = proxy.lastTarget else {
            mapMovedAway = false
            return
        }
        let centerWGS = CoordinateConverter.toWGS84(center)
        let distance = CLLocation(latitude: centerWGS.latitude,
                                  longitude: centerWGS.longitude)
            .distance(from: CLLocation(latitude: target.latitude,
                                       longitude: target.longitude))
        mapMovedAway = distance > Self.movedBannerThreshold
    }

    /// 提示条。文案说的是**事实**：改写没有跟着地图走 —— 目标点还是原来那个。
    private var movedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.slashed")
                .font(.app(12, weight: .semibold))
                .foregroundStyle(themeStore.accent)

            Text(AppLocalization.string("改写仍在原位置生效"))
                .font(.app(12))
                .foregroundStyle(Color.ncText)

            Spacer(minLength: 8)

            Button {
                jumpBackToTarget()
            } label: {
                Text(AppLocalization.string("回到该位置"))
                    .font(.app(12, weight: .semibold))
                    .foregroundStyle(themeStore.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassContainer(cornerRadius: 19, tint: themeStore.glassTint, prominent: true)
    }

    /// 回到改写目标点（存的是 WGS-84，上地图换回地图体系）。
    /// 走唯一入口，顺带把内存目标点与改写目标对齐。
    private func jumpBackToTarget() {
        guard let target = proxy.lastTarget else { return }
        selectTarget(onMap: CoordinateConverter.toGCJ02(target))
        pinnedPlaceName = nil
    }

    // MARK: - 搜索

    /// 搜索框回车。输入能解析成坐标就直接跳坐标（不进地名搜索）；
    /// 否则交给 MKLocalSearch 按地名搜。
    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let parsed = CoordinateInput.parse(text) {
            // 界面开关说的是「这串数字按哪套坐标理解」：
            // WGS-84 → 换算成地图体系再上地图；GCJ-02 → 本来就是地图体系，直接用。
            let onMap = inputSystem == .wgs84
                ? CoordinateConverter.toGCJ02(parsed)
                : parsed
            selectTarget(onMap: onMap)
            // ⚠️ 与 `pickCoordinate` / `pick` 那两条路径**必须一致**
            //（2026-10-15 审查 A2）。以前这里只设 `region` 就 return，漏了两件事：
            //
            // ① 不清 `pinnedPlaceName`：卡片的地名取
            //    `pinnedPlaceName ?? resolvedPlaceName ?? …`，于是**新位置顶着
            //    上一个收藏点的名字**；更糟的是 `onRegionSettled` 里
            //    `if pinnedPlaceName == nil` 会跳过后续所有地名反解，这个错名字
            //    就再也刷不掉了 —— 正是本文件反复强调要杜绝的「界面在撒谎」。
            // ② 不收键盘、不清输入框与候选下拉：跳过去之后地图被键盘挡着。
            pinnedPlaceName = nil
            finishSuggestion()
            return
        }

        searchPlace(text)
    }

    private func searchPlace(_ text: String) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        // 以当前视野为优先范围 —— 搜「麦当劳」出的是附近的，不是全球第一家。
        request.region = region

        // 记下这一轮的世代号，回调里比对（见 `searchStamp`）。
        searchStamp += 1
        let stamp = searchStamp

        MKLocalSearch(request: request).start { [self] response, _ in
            // ⚠️ MapKit 不保证回调在主线程（iOS 16.3 搜索闪退的加固，
            // 2026-10-13）—— 状态更新与键盘收起一律回主线程再做。
            DispatchQueue.main.async { [self] in
                // 这轮已经被更晚的一次搜索取代：结果、报错、收键盘全都不要做。
                guard stamp == searchStamp else { return }

                let items = response?.mapItems ?? []
                guard !items.isEmpty else {
                    showSearchMessage(AppLocalization.string("未找到结果"))
                    return
                }
                // 全称精确检索常常只回主楼一条（2026-10-13 实测：搜
                // 「上海市环球金融中心」只有 1 条）。用户要求「不要局限于
                // 输入的词」—— 带行政区划前缀的，去掉前缀用短词放宽一轮，
                // 主楼/北门/停车楼这类关联条目才会一起出来。
                if items.count < 4,
                   let broad = Self.broadQuery(from: text) {
                    AppLog.debug("搜索", "首轮结果少，放宽检索", details: [
                        "count": "\(items.count)", "broad": broad,
                    ])
                    broadSearch(broad, merging: items, stamp: stamp)
                    return
                }
                commitSearchResults(items, stamp: stamp)
            }
        }
    }

    /// 放宽检索：用去掉行政区划前缀的短词再搜一轮，与第一轮合并。
    ///
    /// `stamp` 原样带到第二轮 —— 放宽检索是**同一轮搜索的后续**，
    /// 世代号必须沿用，否则它会被自己那一轮判成过期而丢掉结果。
    private func broadSearch(_ broad: String, merging primary: [MKMapItem], stamp: Int) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = broad
        request.region = region

        MKLocalSearch(request: request).start { [self] response, _ in
            DispatchQueue.main.async { [self] in
                commitSearchResults(primary + (response?.mapItems ?? []), stamp: stamp)
            }
        }
    }

    /// 去重后写入结果列表。同名同坐标（约 10 米内）算同一条。
    ///
    /// `stamp` 与当前世代号不符时整个函数不生效（含收键盘）——
    /// 过期的响应不该在 UI 上留下任何痕迹。
    private func commitSearchResults(_ items: [MKMapItem], stamp: Int) {
        guard stamp == searchStamp else { return }

        var seen = Set<String>()
        let unique = items.filter { item in
            let coordinate = item.placemark.coordinate
            let key = "\(item.name ?? "")|\(String(format: "%.4f", coordinate.latitude)),\(String(format: "%.4f", coordinate.longitude))"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        AppLog.debug("搜索", "搜索结果合并完成", details: [
            "raw": "\(items.count)", "unique": "\(unique.count)",
        ])
        // ⚠️ 副标题只用 locality / administrativeArea 拼（上一代实现同款配方）。
        // iOS 16.3 闪退根因（2026-10-15 .ips 栈实锤）：对搜索结果的 placemark
        // 发 `subtitle` / `title` 会走消息转发直接崩（unrecognized selector，
        // 崩点在 commitSearchResults）；iOS 26 无此问题。反汇编上一代实现
        // 对照：它的搜索闭包只发 name / placemark / coordinate / locality /
        // administrativeArea，从不发 subtitle / title —— 16.3 真机不闪退。
        // 这里对齐它，用到的 5 个 selector 全部是上一代实现在同一系统验证过的。
        searchResults = unique.prefix(10).map { item in
            let pm = item.placemark
            let city = pm.locality ?? ""
            let province = pm.administrativeArea ?? ""
            var parts = [city, province].filter { !$0.isEmpty }
            if parts.count == 2, parts[0] == parts[1] { parts = [parts[0]] }
            let subtitle = parts.joined(separator: " · ")
            return SearchHit(title: item.name ?? AppLocalization.string("未命名位置"),
                             subtitle: subtitle,
                             coordinate: pm.coordinate)
        }
        // 搜完收起键盘，让结果列表完整露出来。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    /// 「上海市环球金融中心」→「环球金融中心」。
    ///
    /// 规则：可先剥「中国」，再在前 5 个字内找到「市」就把到「市」为止的
    /// 行政区划头整段截掉；港澳同理。截完为空或没有前缀就返回 nil
    /// （不需要放宽）。只服务**检索放宽**这一件事，不做语义保证 ——
    /// 「东方市」这类边缘case 放宽了也无害，多一轮兜底检索而已。
    static func broadQuery(from text: String) -> String? {
        var t = text
        if t.hasPrefix("中国") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("香港") || t.hasPrefix("澳门") {
            let rest = String(t.dropFirst(2))
            return rest.isEmpty ? nil : rest
        }
        if let idx = t.firstIndex(of: "市"),
           t.distance(from: t.startIndex, to: idx) <= 4 {
            let rest = String(t[t.index(after: idx)...])
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// 搜索反馈小胶囊：显示 2.5 秒自动消失。
    private func showSearchMessage(_ text: String) {
        withAnimation { searchMessage = text }
        searchMessageTask?.cancel()
        searchMessageTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { searchMessage = nil }
        }
    }

    // MARK: - 动作

    /// 主按钮。
    ///
    /// **「开启虚拟定位」是两步**：先把代理拉起来（这是「改写能上路」的前提），
    /// 再启动校验。少任何一步，用户拿到的都是「系统未刷新」——
    /// 因为校验器问不出「代理通不通」，只能保守地报后者，把人引去重启设备。
    ///
    /// **「停止」只关改写和校验，不动代理监听**：Wi-Fi 里还配着
    /// `127.0.0.1:8888`，代理一停用户就断网。这是整个设计的支点。
    // MARK: - 开启闸门（网络 / 代理冲突）

    /// 主按钮的开启闸门。非 nil = 当前不允许开启，按钮禁用并显示原因。
    private enum GateHint: Equatable {
        /// 默认网络路径不是 Wi-Fi —— 蜂窝下系统没有 HTTP 代理配置，开了也白开。
        case notWiFi
        /// 系统全局 HTTP 代理压根没启用 —— 十有八九是**忘了配或没配成功**
        ///（2026-10-12 用户实测踩过：以为配了，白测半天）。
        case proxyNotConfigured
        /// 系统全局 HTTP 代理指向别处 —— 多半开着其他代理软件。
        case proxyConflict(host: String, port: Int)
    }

    /// 只在「未开启」时做闸门检查：已经开着的时候，就算网络变了也不拦
    /// 「停止」操作 —— 让用户能随时关掉，而不是被锁死在开启态。
    ///
    /// ⚠️ 结果带 1.5 秒缓存（2026-10-13 性能审查）：`conflict()` 与
    /// `isConfigured()` 各要一次 `CFNetworkCopySystemProxySettings`
    /// 系统调用，而 body 在拖地图、状态行刷新时高频重算 —— 不能每帧都查。
    ///
    /// ⚠️ **缓存只在 `refreshGateHint()` 里写，`body` 求值期只读**
    ///（2026-10-15 审查 A9）。改之前是「读的时候顺手回写」—— 那等于在 `body`
    /// 里改 `@State`，命中 SwiftUI 官方的
    /// 「Modifying state during view update, this will cause undefined behavior」：
    /// 拖地图每次重算、只要离上次写超过 1.5 秒就会踩一次。
    ///
    /// 写入点因此改成几个**真实变化事件**（见 `gateRefreshPoints` 注释处）：
    /// 出现在屏上、回到前台、校验状态变化、网络路径变化、连接设置页关掉。
    @State private var gateCache: (hint: GateHint?, at: Date)?

    private static let gateCacheTTL: TimeInterval = 1.5

    private var gateHint: GateHint? {
        if let gateCache, Date().timeIntervalSince(gateCache.at) < Self.gateCacheTTL {
            return gateCache.hint
        }
        // 缓存过期（事件驱动的写入点已经覆盖，正常不会走到）：
        // 现算给本次渲染用，但**不回写** —— 绝不在 body 求值期碰状态。
        return computeGateHint()
    }

    /// 闸门缓存的**唯一写入点**。只能在 `body` 之外调用。
    private func refreshGateHint() {
        gateCache = (computeGateHint(), Date())
    }

    /// 冷启动把校验循环接回来（2026-10-15 审查 A3）。
    ///
    /// 代理会按盘里的 `patchingEnabled` 自动恢复改写（`restoreIfNeeded`），
    /// 但 `SpoofEffectVerifier` 是**全新进程、全新实例**，`state == .idle`；
    /// 而主按钮的文案/图标、状态行的结论胶囊**全部只看 `state`**
    ///（全工程只有 `onAppear` 与「挪走」提示读过 `proxy.isPatching`）。
    ///
    /// 不接这一下，冷启动后会出现自相矛盾的界面：主按钮写着「开启虚拟定位」、
    /// 状态行只有「内置代理 / 证书」两颗胶囊，**没有任何东西说明定位正在被改写**；
    /// 此时一拖地图反而会弹出「改写仍在原位置生效」。
    ///
    /// 目标点用 `proxy.lastTarget`（改写真正生效的点），不是地图中心。
    private func resumeVerificationIfPatching() {
        guard proxy.isPatching, let target = proxy.lastTarget else { return }
        verifier.start(target: target)
    }

    private func computeGateHint() -> GateHint? {
        guard state == .idle else { return nil }
        // 第三方模式没有闸门：Wi-Fi 代理、8888 端口这些检查全是内置
        // 代理专属的；模块在不在，点按钮当场就有结论（probe 通道）。
        if isThirdPartyMode { return nil }
        if networkMonitor.hasResult, !networkMonitor.isWiFi {
            return .notWiFi
        }
        // 三种现场按顺序排查：没配 / 配了但被抢 / 放行。
        if let foreign = ProxyConflictDetector.conflict() {
            return .proxyConflict(host: foreign.host, port: foreign.port)
        }
        if !ProxyConflictDetector.isConfigured() {
            return .proxyNotConfigured
        }
        return nil
    }

    private var primaryButtonEnabled: Bool { gateHint == nil }

    private func gateHintRow(_ hint: GateHint) -> some View {
        Button {
            // 没配代理这一档直接把人送去连接设置 —— 那是唯一要动手的地方。
            if hint == .proxyNotConfigured {
                showConnectionSetup = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: gateHintIcon(hint))
                    .font(.app(12, weight: .semibold))
                    .foregroundStyle(StatusTint.ineffective.color)

                Text(gateHintText(hint))
                    .font(.app(12))
                    .foregroundStyle(Color.ncText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if hint == .proxyNotConfigured {
                    Image(systemName: "chevron.right")
                        .font(.app(11, weight: .semibold))
                        .foregroundStyle(Color.ncTextTertiary)
                }
            }
            .padding(10)
            .background(
                StatusTint.ineffective.color.opacity(StatusTint.fillOpacity),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func gateHintIcon(_ hint: GateHint) -> String {
        switch hint {
        case .notWiFi: return "wifi.exclamationmark"
        case .proxyNotConfigured: return "wifi.slash"
        case .proxyConflict: return "exclamationmark.shield.fill"
        }
    }

    private func gateHintText(_ hint: GateHint) -> String {
        switch hint {
        case .notWiFi:
            return AppLocalization.string("当前不是 Wi-Fi 网络：虚拟定位依赖 Wi-Fi 代理，请先连接 Wi-Fi。")
        case .proxyNotConfigured:
            return AppLocalization.string("Wi-Fi 代理还没配置：点这里去连接设置，把代理指向 127.0.0.1:8888。")
        case .proxyConflict(let host, let port):
            return AppLocalization.string(
                "检测到系统代理指向 %@:%ld，可能开着其他代理软件，请先关闭再试。",
                host, port)
        }
    }

    private func toggleSpoofing() {
        // 第三方模式：不经内置代理，直接向客户端模块写/清坐标。
        #if THIRD_PARTY_MODE
        if isThirdPartyMode { toggleThirdPartySpoofing(); return }
        #endif

        // ⚠️ 「重试」必须真的重试（2026-10-15 审查 A4）。
        //
        // 按钮文案由 `primaryTitle` 按 `proxy.status.isFailed` 决定，而下面那个
        // `switch` 只看 `verifier.state`（`primaryIcon` 同理）—— 两边口径不一致
        // 的后果是：改写生效中回到前台、链路探测失败触发
        // `ProxyController.recoverAfterForeground` → `restart()` 失败
        // （端口被占 / 证书不可用）→ `status` 变 `.failed` 而 `state` 仍是
        // `.effective`。此时按钮写着「重试」，点下去执行的却是**停止 + 清校验**，
        // 用户以为在修，实际被关掉。
        if proxy.status.isFailed, verifier.state != .idle {
            retryProxy()
            return
        }

        switch verifier.state {
        case .idle:
            // 与按钮禁用态同一套闸门 —— 双保险：万一按钮态没来得及刷新
            // （网络刚切换），也不该把一个注定失败的改写放出去。
            guard primaryButtonEnabled else { return }
            do {
                // 下发与校验用的是**同一个 WGS-84 值** ——
                // 代理按 bridge.go 的契约收 WGS-84，校验器比对的也是系统回读的
                // WGS-84，两处必须一致，换算只做一次。
                try proxy.ensureRunning(at: proxyCoordinate)
                proxy.setPatching(true)
                verifier.start(target: proxyCoordinate)
            } catch let failure as ProxyController.Failure {
                proxyAlert = ProxyController.Alert(failure: failure)
            } catch {
                proxyAlert = ProxyController.Alert(failure: .startFailed)
            }

        case .verifying, .effective, .ineffective:
            proxy.setPatching(false)
            verifier.reset()
            mapMovedAway = false
        }
    }

    /// 「重试」：把代理拉起来、保持改写开启，再跑一轮校验。
    ///
    /// 目标点用 `proxy.lastTarget`（改写真正生效的点），不是当前地图中心 ——
    /// 用户点这颗是想把**断掉的代理接回来**，不是想换个位置；用地图中心会
    /// 顺手把目标点也改了。`lastTarget` 缺失时才兜底到地图中心。
    private func retryProxy() {
        let target = proxy.lastTarget ?? proxyCoordinate
        do {
            try proxy.ensureRunning(at: target)
            proxy.setPatching(true)
            verifier.start(target: target)
        } catch let failure as ProxyController.Failure {
            proxyAlert = ProxyController.Alert(failure: failure)
        } catch {
            proxyAlert = ProxyController.Alert(failure: .startFailed)
        }
    }

    #if THIRD_PARTY_MODE
    /// 第三方模式的开启/停止：向客户端模块写坐标 / 清坐标。
    /// 成败当场给结论 —— probe 请求本身就是链路探针。
    private func toggleThirdPartySpoofing() {
        Task { @MainActor in
            if thirdParty.state == .active {
                let ok = await thirdParty.deactivate()
                if ok {
                    // 与内置停止路径同一套收尾：停校验循环、清「挪走」标记。
                    verifier.reset()
                    mapMovedAway = false
                }
            } else {
                // 下发体系与内置代理一致：WGS-84。
                let target = proxyCoordinate
                let ok = await thirdParty.activate(latitude: target.latitude,
                                                   longitude: target.longitude)
                if ok {
                    // 与内置代理共用同一份「上次位置」，冷启动对准照常工作。
                    proxy.recordTarget(target)
                    // 与内置开启路径对齐：立即进入校验循环 —— 第三方模式下
                    // 校验器照常工作（它只看系统回读的位置），iOS 26 的
                    // 「需重启设备」结论也会从这里给出来。
                    verifier.start(target: target)
                }
            }
        }
    }

    /// 第三方模式状态行的模块胶囊：绿 = 链路通（probe 拿到了模块应答），
    /// 橙 = 不通。诊断回显（diag）非空说明改写脚本真的在跑。
    @ViewBuilder
    private var modulePill: some View {
        // 「还没测过」保持中性 —— 不能把不知道说成好/坏。
        if thirdParty.state == .unknown {
            NeutralPill(text: thirdParty.statusText,
                        systemImage: "arrow.triangle.branch")
        } else {
            StatusPill(text: thirdParty.statusText,
                       tint: thirdParty.state == .unreachable ? .ineffective : .effective,
                       systemImage: thirdParty.state == .unreachable ? "arrow.triangle.branch" : "checkmark.seal.fill")
        }
    }
    #endif

    /// 回到真实位置。
    ///
    /// 「实时位置」按钮：三段循环（用户拍板 2026-10-13；档位口径
    /// 2026-10-14 对齐高德——比例尺读数 200米 ↔ 50米）。
    ///
    /// - 地图**不在**实时位置上：定位一次并居中，视野跨度不变；
    /// - 已经居中：宽视野 → 收到 200米档；再点 → 50米档；再点 → 回 200米档；
    /// - 中途把地图挪走了：下次点击回到第一段，重新居中。
    ///
    // MARK: - 选点针

    // 选点针 2026-10-15 拍板后由 `MapLayer` 以 MKAnnotationView 钉在
    // 目标坐标上（贴图渲染、描边、锚点几何都在那边），
    // 本文件不再持有针的绘制代码。

    /// **档位是「比例尺读数」不是「纬度跨度」**（2026-10-14 用户拿高德
    /// 截图对拍：同样的档位，高德一屏约 800 米宽，我们旧实现一屏才 200 米
    /// ——差了约 8 倍，建筑全糊成色块）。高德的尺子约 100pt 长读作
    /// 200米/50米，折算即每屏幕点 2.0 / 0.5 米。
    private static func spanLatitudeDelta(metersPerPoint: Double) -> Double {
        // 地图 ignoresSafeArea 全屏铺，屏幕高度即视野高度
        //（UIScreen.bounds 随界面方向，App 内恒等于地图高度）。
        let mapPoints = UIScreen.main.bounds.height
        return mapPoints * metersPerPoint / 111_320
    }

    // 档位 2026-10-14 用户二次拍板：「视角再高点 = 缩小 = 看到更多」，
    // 比高德同档整体再拉远约 20%（2.0→2.4 / 0.5→0.6）。
    private var zoomSpan200m: Double { Self.spanLatitudeDelta(metersPerPoint: 2.4) }
    private var zoomSpan50m: Double { Self.spanLatitudeDelta(metersPerPoint: 0.6) }
    /// 档位分界（几何判断，不记状态——「挪走了再点」天然回到第一段）：
    /// - 比 200米档还宽 2 倍以上 = 宽视野 → 收到 200米档；
    /// - 在两档之间 = 已在 200米档 → 再收一档到 50米档；
    /// - 比 50米档还窄 = 已在 50米档 → 回 200米档。
    /// （档位值 2026-10-14 用户拍板：在高德同档基础上整体再放大一档。）
    private var zoomStageWideBoundary: Double { zoomSpan200m * 2 }
    private var zoomStageNarrowBoundary: Double { zoomSpan50m * 2 }

    private func moveToRealLocation() {
        pinnedPlaceName = nil
        // 第二段起：已在实时位置上 → 档位循环。
        if let real = realLocation,
           isCentered(on: real) {
            let latitudeDelta = region.span.latitudeDelta
            let nextSpan: Double
            if latitudeDelta >= zoomStageWideBoundary || latitudeDelta <= zoomStageNarrowBoundary {
                nextSpan = zoomSpan200m
            } else {
                nextSpan = zoomSpan50m
            }
            zoomSpanTo(nextSpan)
            return
        }

        // 第一段：定位并居中。`RealLocationProvider` 给的是 **WGS-84**（GPS
        // 原始值），直接丢给地图会偏出几百米 —— 境内地图是 GCJ-02，必须换算。
        //
        // ⚠️ 2026-10-15 拍板后这里是**纯视野动作**：只把地图挪到实时位置，
        // 不改目标点 —— 针留在原地，「选点」与「实时」一眼分开。
        locationProvider.requestOnce { result in
            switch result {
            case .success(let coordinate):
                let onMap = CoordinateConverter.toGCJ02(coordinate)
                realLocation = onMap
                region = MKCoordinateRegion(center: onMap, span: region.span)

            case .failure(let failure):
                locationFailure = failure
            }
        }
    }

    /// 地图中心是否已经落在实时位置附近（容忍可见高度的 10%）。
    private func isCentered(on coordinate: CLLocationCoordinate2D) -> Bool {
        let toleranceMeters = Double(region.span.latitudeDelta) * 111_000 * 0.1
        let center = CLLocation(latitude: region.center.latitude,
                                longitude: region.center.longitude)
        let target = CLLocation(latitude: coordinate.latitude,
                                longitude: coordinate.longitude)
        return center.distance(from: target) <= max(toleranceMeters, 30)
    }

    /// 把视野跨度收到指定值；保持当前地图的横纵比例，只缩跨度、不动中心。
    private func zoomSpanTo(_ latitudeDelta: Double) {
        let ratio = region.span.longitudeDelta / max(region.span.latitudeDelta, 0.0001)
        let clampedRatio = min(max(ratio, 0.2), 5)
        region = MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta,
                                   longitudeDelta: latitudeDelta * clampedRatio))
    }

    private static func describe(_ failure: RealLocationProvider.Failure) -> String {
        switch failure {
        case .denied:
            return AppLocalization.string("定位权限未开启，请在系统设置中允许访问位置。")
        case .restricted:
            return AppLocalization.string("当前设备限制了定位功能，无法获取真实位置。")
        case .unavailable(let reason):
            return reason
        }
    }

    private var locationAlertBinding: Binding<Bool> {
        Binding(
            get: { locationFailure != nil },
            set: { if !$0 { locationFailure = nil } }
        )
    }

    private var primaryTitle: String {
        #if THIRD_PARTY_MODE
        if isThirdPartyMode {
            return thirdParty.state == .active
                ? AppLocalization.string("停止虚拟定位")
                : AppLocalization.string("开启虚拟定位")
        }
        #endif
        if proxy.status.isFailed { return AppLocalization.string("重试") }

        switch state {
        case .idle: return AppLocalization.string("开启虚拟定位")
        // 按钮写的是「点下去会发生什么」，所以这里不写「验证中」——
        // 状态胶囊已经在报「验证中」了，按钮再重复一遍反而让人以为点不动。
        case .verifying, .effective, .ineffective: return AppLocalization.string("停止虚拟定位")
        }
    }

    private var primaryIcon: String? {
        #if THIRD_PARTY_MODE
        if isThirdPartyMode {
            return thirdParty.state == .active ? "stop.circle.fill" : "location.fill"
        }
        #endif
        // 与 `primaryTitle` 的 `if proxy.status.isFailed { return "重试" }` 对齐：
        // 文案是「重试」、动作也是重试（见 `retryProxy`），图标就不能还是「停止」
        // —— 否则这颗按钮自己有三套说法（2026-10-15 审查 A4）。
        if proxy.status.isFailed { return "arrow.clockwise" }

        switch state {
        case .idle: return "location.fill"
        case .verifying: return "stop.circle.fill"
        case .effective, .ineffective: return "stop.circle.fill"
        }
    }

    // MARK: - 界面测试注入口

    /// 用启动参数直接打开某个二级页面，省掉点击。
    ///
    /// 只在 Debug 下存在（`UI_TEST_HOOKS` 条件，见 `project.yml`）——
    /// 出包走 Release，这段代码根本不会被编进去。
    ///
    /// 用法：`simctl launch ... com.xxx.loc -uiTest.initialSheet connection`
    private func applyUITestEntryIfNeeded() {
        #if UI_TEST_HOOKS
        guard !didApplyUITestEntry else { return }

        // 独立钩子：烟测第三方状态行完整形态（第三方代理 + 模块 + 校验器同排）。
        // 真实 active 需要手机上的代理客户端，模拟器给不了，只能注入。
        // 放在 initialSheet 的 guard 之前 —— 那个 guard 在没传该参数时会
        // 提前 return，这里就永远执行不到了。
        #if THIRD_PARTY_MODE && UI_TEST_HOOKS
        if UserDefaults.standard.string(forKey: "uiTest.thirdPartyActive") != nil {
            didApplyUITestEntry = true
            thirdParty.forceActiveForUITest(latitude: 31.233968, longitude: 121.505760)
            // 与真实开启路径一致：起校验循环，让结论胶囊 + 刷新按钮同框。
            verifier.start(target: proxyCoordinate)
            return
        }
        #endif

        // 烟测钩子：预填搜索词并触发一次回车搜索 —— 模拟器没有打字手段，
        // 搜索链路（候选 → 回车 → 结果列表 → 相关地点）只能这样走真实路径。
        if let searchText = UserDefaults.standard.string(forKey: "uiTest.searchQuery") {
            didApplyUITestEntry = true
            query = searchText
            suggester.update(query: searchText, region: region)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                submitSearch()
            }
            return
        }

        // 烟测钩子：直接展开图层胶囊 —— 模拟器没有点击手段，弹层只能注入。
        if UserDefaults.standard.object(forKey: "uiTest.layerMenu") != nil {
            didApplyUITestEntry = true
            showsLayerMenu = true
            return
        }

        // 烟测钩子：把视野钉到指定档位（每屏幕点的实地米数）——
        // 只用于生成比例对比图，不影响任何产品行为。
        if let metersPerPoint = UserDefaults.standard.object(forKey: "uiTest.metersPerPoint") as? Double {
            didApplyUITestEntry = true
            let mapPoints = UIScreen.main.bounds.height
            let latitudeDelta = mapPoints * metersPerPoint / 111_320
            region = MKCoordinateRegion(
                center: region.center,
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: latitudeDelta)
            )
        }

        guard let entry = UserDefaults.standard.string(forKey: "uiTest.initialSheet") else { return }
        didApplyUITestEntry = true

        switch entry {
        case "settings": showSettings = true
        case "connection": showConnectionSetup = true
        case "diagnostics": showDiagnostics = true
        case "manual": showManual = true
        #if UI_TEST_HOOKS
        case "runmode": showRunMode = true
        #endif
        default: break
        }
        #endif
    }

    /// 端到端实测钩子：`-uiTest.autoSpoof "39.9042,116.4074"`（WGS-84 目标点）。
    ///
    /// 模拟器没有触控手段，这个钩子把「把地图挪到目标点 → 点开启」这两个
    /// 人工动作原样自动化 —— 走的还是 `toggleSpoofing()` 主路径，不是旁路。
    /// 坐标按 WGS-84 解释（下发体系），界面显示交给现有的换算链。
    private func applyAutoSpoofIfNeeded() {
        #if UI_TEST_HOOKS
        guard !didApplyAutoSpoof else { return }
        guard let raw = UserDefaults.standard.string(forKey: "uiTest.autoSpoof"),
              let target = CoordinateInput.parse(raw) else { return }
        didApplyAutoSpoof = true

        // 目标点搬进视野（地图体系），让 onRegionSettled / 提示条逻辑
        // 与人工操作完全同路径 —— 走唯一入口，目标点同步设好。
        selectTarget(onMap: CoordinateConverter.toGCJ02(target))

        // 等地图落定、地名解析发出后再开，日志时序才和人点的一样。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            AppLog.info("界面测试", "自动开启虚拟定位（uiTest.autoSpoof）")
            toggleSpoofing()
        }
        #endif
    }
}

/// 坐标行尾的复制小图标：点一下把该行坐标写进剪贴板。
///
/// 反馈靠图标自身变化（变成对勾一秒）—— 不弹横幅，两行坐标各带一颗，
/// 弹窗反而吵。上一代实现同款交互（点哪行复制哪行）。
private struct CoordinateCopyIcon: View {

    let accessibilityLabel: String
    let value: String

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.app(10, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.ncTextTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.string("复制坐标") + " " + accessibilityLabel)
    }
}
