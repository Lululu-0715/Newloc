import MapKit
import SwiftUI

/// 地图层。
///
/// **为什么不用 SwiftUI 的 `Map`**：`MapStyle` / `.mapStyle` 是 **iOS 17+**，
/// 而本工程硬性要求从 iOS 15 起。想要在这条线上支持「图层」切换
/// （标准 / 卫星 / 混合），唯一可行的路是 `MKMapView.mapType` —— 它从 iOS 3 就在。
/// 上一代实现的 `MinimumOSVersion` 是 15.0，却能切图层，走的正是这条路。
///
/// **为什么 region 要双向绑定**：用户拖地图要把新中心点带出来（它就是要下发的坐标），
/// 而「回到真实位置」「搜索结果跳转」又要把新中心点推进去。两条路必须收敛而不是互拽 ——
/// 收敛靠 `updateUIView` 里的容差比较，那里有详细注释。
struct MapLayer: UIViewRepresentable {

    /// 地图中心与跨度。用户拖动会写回；程序跳转读它。
    @Binding var region: MKCoordinateRegion

    /// 图层。
    var mapType: MKMapType = .standard

    /// 真实位置。有值就在地图上画一个圆点，无值不画。
    ///
    /// 用系统 annotation 而不是自绘 —— 它要跟着地图一起平移缩放，
    /// 而 SwiftUI 的 overlay 拿不到「坐标 → 屏幕点」的换算。
    var realLocation: CLLocationCoordinate2D?

    /// 选点针钉住的**目标坐标**（地图体系 GCJ-02）。
    ///
    /// 2026-10-15 拍板：针从「地图中心 overlay」改成钉在目标坐标的
    /// annotation —— 拖走地图时针留在目标点上，「选点」与「实时位置」
    /// 一眼分开。和圆点同理，必须走 annotation 才能跟着地图坐标系走。
    var targetPin: CLLocationCoordinate2D?

    /// 实时位置圆点的颜色 = 主题强调色（2026-10-13 用户要求跟随主题）。
    /// 选点针与它同色（2026-10-14 拍板），描边另给。
    var accentColor: Color = .black

    /// 选点针描边色 = 与强调色**对立**的那支（黑白主题：浅色白 / 深色黑）。
    /// 针尖扎进同色实时圆点时靠它保住针身轮廓。
    var pinOutlineColor: Color = .white

    /// 用户点地图。回调里的坐标是**地图体系（境内 GCJ-02）**，调用方负责换算。
    var onSelectCoordinate: (CLLocationCoordinate2D) -> Void = { _ in }

    /// 拖动 / 缩放**停稳**后的新中心。地名解析靠它触发 ——
    /// 每次手势只解析一次，不做连续解析（那既费配额也跟不上手速）。
    var onRegionSettled: (CLLocationCoordinate2D) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = mapType
        mapView.setRegion(region, animated: false)

        // 界面自己画了顶部搜索、右侧浮标、底部卡片。系统自带的指南针与比例尺
        // 会跟它们抢位置，而且不跟随本工程的黑白主题。
        mapView.showsCompass = false
        mapView.showsScale = false
        // 系统的定位蓝点一定是蓝色，且会盖住自绘的选点针，所以关掉，自己画。
        mapView.showsUserLocation = false
        // 旋转与俯仰对本应用没有意义：用户要看的是「落点在哪」，
        // 地图被转成一个奇怪角度只会让人对不上路网。
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // 地图自带双击放大。单击手势若不避让，双击时也会先识别成一次落点。
        // 让单击等双击失败之后再触发（代价是约 0.3 秒延迟，能接受）。
        if let doubleTap = mapView.gestureRecognizers?.first(where: {
            ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 2
        }) {
            tap.require(toFail: doubleTap)
        }
        mapView.addGestureRecognizer(tap)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // SwiftUI 每次重算都会造一个新的 struct，协调器手里那份要跟上，
        // 否则它调用的闭包与 binding 会指向已经过期的视图。
        context.coordinator.parent = self

        if mapView.mapType != mapType {
            mapView.mapType = mapType
        }

        context.coordinator.syncRealLocation(on: mapView, to: realLocation)
        context.coordinator.syncTargetPin(on: mapView, to: targetPin)
        // 主题色可能在上层被换掉：原地换圆点贴图，不必重建 annotation。
        context.coordinator.refreshDotIfNeeded(on: mapView, accent: accentColor)
        context.coordinator.refreshPinIfNeeded(on: mapView, accent: accentColor, outline: pinOutlineColor)

        // **只在「外部真的改了 region」时才移动地图。**
        //
        // 判断基准**不是** `mapView.region` 与 binding 的差值，而是协调器记录的
        // `lastKnownRegion`（2026-10-13 修「快速滑动回弹、拖动卡顿」）：
        // 用户拖动/惯性期间，校验器等任何 `@Published` 变化都会重算 body 并
        // 走进这里 —— 此时 binding 还停在**上一次停稳**的旧值，与已被拖走的
        // `mapView.region` 必然不等。旧实现据此调 `setRegion`，把地图当场
        // 拽回去 —— 用户看到的就是「快速滑动会回弹、滑起来卡卡的」。
        // 现在只有 binding 与 `lastKnownRegion` 不同（= 程序侧真的跳转了：
        // 搜索、收藏、点选、回到目标点）才移动地图；用户手势产生的差异由
        // delegate 写回后自然相等，不再触发任何 setRegion。
        guard !region.isNearlyEqual(to: context.coordinator.lastKnownRegion) else { return }
        context.coordinator.lastKnownRegion = region
        mapView.setRegion(region, animated: true)
    }

    // MARK: - 协调器

    final class Coordinator: NSObject, MKMapViewDelegate {

        var parent: MapLayer

        /// 双方最近一次共识的 region。
        ///
        /// `updateUIView` 靠它分辨「程序侧真的改了 binding」与「只是一次
        /// 无关的重算」——详见 `updateUIView` 里的说明。delegate 写回、
        /// 程序 setRegion 两个方向都会同步它。
        var lastKnownRegion: MKCoordinateRegion

        /// 真实位置那个圆点。持有引用是为了原地更新它的坐标，
        /// 而不是每次 `updateUIView` 都删掉重加（那会闪）。
        private var realLocationAnnotation: MKPointAnnotation?

        /// 选点针。与圆点同理持有引用，坐标变了原地挪。
        private var targetAnnotation: MKPointAnnotation?

        private static let realLocationReuseIdentifier = "NewlocRealLocationDot"
        private static let targetPinReuseIdentifier = "NewlocTargetPin"

        /// 主题色缓存：强调色没变就不重画（重画很便宜，但 updateUIView 高频）。
        private var cachedAccent: Color?
        private var cachedDot: UIImage?
        private var cachedPinAccent: Color?
        private var cachedPinOutline: Color?
        private var cachedPin: UIImage?

        /// 实时位置圆点：**主题色 + 白环**（2026-10-13 用户要求：
        /// 跟随主题色，加大 —— 原来的 14pt 黑白点在地图上太小看不清）。
        ///
        /// 白环必须保留：主题色可能是深也可能是浅，白环保证圆点压在
        /// 任意底图（标准图 / 卫星图 / 深色模式）上都有一圈清晰边界。
        private func realLocationDot(accent: Color) -> UIImage {
            if let cachedDot, cachedAccent == accent { return cachedDot }
            let size = CGSize(width: 22, height: 22)
            let coreColor = UIColor(accent)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.white.setFill()
                context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
                coreColor.setFill()
                context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size)
                    .insetBy(dx: 4, dy: 4))
            }
            cachedAccent = accent
            cachedDot = image
            return image
        }

        // MARK: 选点针

        /// 选点针的固定高度（pt）。
        /// 刻意**不随「设置 → 字体大小」缩放** —— 针是地图上的指示物，
        /// 不是文字。跟着字号变异步，针尖就会偏出坐标点（2026-10-14 用户实测）。
        private static let pinGlyphHeight: CGFloat = 34

        /// 描边硬偏移宽度（pt）。与旧 overlay 版一致：`.shadow(radius: 0)`
        /// 的四向硬拷贝 —— **不能用模糊版**，针尖是渐收的锥形，模糊光晕
        /// 在针尖处比针身还宽，压在同色圆心上会糊成一团灰
        /// （2026-10-14 模拟器 1:1 实测）。
        private static let pinOutlineWidth: CGFloat = 0.8

        /// 画布四周留白 = 一圈描边的宽度（防描边被裁）+ 落影的呼吸空间。
        private static var pinCanvasMargin: CGFloat { pinOutlineWidth * 2 + 4 }

        /// 选点针贴图：`mappin` 符号 + 四向硬偏移描边 + 落影，
        /// 与旧 overlay 版（2026-10-14 定稿）观感一致。
        ///
        /// ⚠️ 符号必须用 `mappin`：**`mappin.fill` 不存在于 SF Symbols**
        /// （2026-10-13 模拟器实测：fill 变体渲染为空白）。
        /// MKAnnotationView 只吃 UIImage，所以在位图里复刻 SwiftUI 那套
        /// `foregroundStyle + shadow` 叠加。落影（黑 25%、模糊 1.5、下移 1）
        /// 不是造型 —— 是让针压在卫星图、深色底图上仍读得出来。
        private func pinImage(accent: Color, outline: Color) -> UIImage {
            if let cachedPin, cachedPinAccent == accent, cachedPinOutline == outline { return cachedPin }

            // pointSize 只是字号的基准，glyph 实际高度与之不成正比 ——
            // 先裁掉透明边再缩放到目标高度，保证**视觉针高**恰好 34pt。
            let raw = UIImage(systemName: "mappin", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 100, weight: .semibold))
                ?? UIImage()
            let base = Self.trimmedTransparentEdges(of: raw)
            let scale = base.size.height > 0 ? Self.pinGlyphHeight / base.size.height : 1
            let glyphSize = CGSize(width: base.size.width * scale, height: Self.pinGlyphHeight)
            let margin = Self.pinCanvasMargin
            let canvas = CGSize(width: glyphSize.width + margin * 2,
                                height: glyphSize.height + margin * 2)

            let accentImage = base.withTintColor(UIColor(accent), renderingMode: .alwaysOriginal)
            let outlineImage = base.withTintColor(UIColor(outline), renderingMode: .alwaysOriginal)
            let glyphRect = CGRect(origin: CGPoint(x: margin, y: margin), size: glyphSize)

            let image = UIGraphicsImageRenderer(size: canvas).image { context in
                let cg = context.cgContext
                // 落影先设：随后画上去的内容都会带阴影。
                cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5,
                             color: UIColor.black.withAlphaComponent(0.25).cgColor)
                let offsets: [(CGFloat, CGFloat)] = [
                    (-Self.pinOutlineWidth, 0), (Self.pinOutlineWidth, 0),
                    (0, -Self.pinOutlineWidth), (0, Self.pinOutlineWidth),
                ]
                for (dx, dy) in offsets {
                    outlineImage.draw(in: glyphRect.offsetBy(dx: dx, dy: dy))
                }
                accentImage.draw(in: glyphRect)
            }

            cachedPinAccent = accent
            cachedPinOutline = outline
            cachedPin = image
            return image
        }

        /// 裁掉符号布局框的透明内边距。
        ///
        /// SF 符号的 bounding box 自带内边距，直接按 bounding box 缩放的话，
        /// 「贴图高 34pt」≠「视觉 glyph 高 34pt」，针尖会悬在坐标点上方
        /// （2026-10-15 模拟器实测悬了约 2pt）。用符号自带的
        /// `alignmentRectInsets`（glyph 相对布局框的边距，官方口径）
        /// 裁边之后，针高与锚点全部几何确定，不再依赖内边距的具体数值。
        private static func trimmedTransparentEdges(of image: UIImage) -> UIImage {
            guard let cg = image.cgImage else { return image }
            let insets = image.alignmentRectInsets
            let s = image.scale
            let rect = CGRect(x: insets.left * s,
                              y: insets.top * s,
                              width: CGFloat(cg.width) - (insets.left + insets.right) * s,
                              height: CGFloat(cg.height) - (insets.top + insets.bottom) * s)
            guard rect.width >= 1, rect.height >= 1,
                  let cropped = cg.cropping(to: rect.integral) else { return image }
            return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
        }

        init(_ parent: MapLayer) {
            self.parent = parent
            self.lastKnownRegion = parent.region
        }

        /// 用户拖动 / 缩放结束后，把地图的新中心写回界面。
        ///
        /// 只在**结束后**触发（不是每帧），所以这里写 binding 不会拖累拖动性能。
        /// 写回的同时同步 `lastKnownRegion` —— 这一笔让随后的 body 重算
        /// 在 `updateUIView` 里判等通过，不再触发多余的 `setRegion`。
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.region = mapView.region
            lastKnownRegion = mapView.region
            parent.onRegionSettled(mapView.region.center)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let mapView = gesture.view as? MKMapView else { return }

            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onSelectCoordinate(coordinate)
        }

        // MARK: 真实位置圆点

        func syncRealLocation(on mapView: MKMapView,
                              to coordinate: CLLocationCoordinate2D?) {
            guard let coordinate else {
                if let existing = realLocationAnnotation {
                    mapView.removeAnnotation(existing)
                    realLocationAnnotation = nil
                }
                return
            }

            if let existing = realLocationAnnotation {
                // 先比较再赋值 —— 无谓的赋值会让地图重新布局一次 annotation。
                if !existing.coordinate.isNearlyEqual(to: coordinate) {
                    existing.coordinate = coordinate
                }
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = coordinate
                mapView.addAnnotation(annotation)
                realLocationAnnotation = annotation
            }
        }

        /// 主题色变了：给已经挂着的 annotation 原地换贴图。
        func refreshDotIfNeeded(on mapView: MKMapView, accent: Color) {
            guard let annotation = realLocationAnnotation,
                  cachedAccent != accent,
                  let view = mapView.view(for: annotation) else { return }
            view.image = realLocationDot(accent: accent)
        }

        // MARK: 选点针

        /// 目标坐标变更时原地挪针；首次给值时挂上。
        func syncTargetPin(on mapView: MKMapView,
                           to coordinate: CLLocationCoordinate2D?) {
            guard let coordinate else {
                if let existing = targetAnnotation {
                    mapView.removeAnnotation(existing)
                    targetAnnotation = nil
                }
                return
            }

            if let existing = targetAnnotation {
                if !existing.coordinate.isNearlyEqual(to: coordinate) {
                    existing.coordinate = coordinate
                }
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = coordinate
                mapView.addAnnotation(annotation)
                targetAnnotation = annotation
            }
        }

        /// 主题色 / 描边色变了：原地换针贴图。
        func refreshPinIfNeeded(on mapView: MKMapView, accent: Color, outline: Color) {
            guard let annotation = targetAnnotation,
                  cachedPinAccent != accent || cachedPinOutline != outline,
                  let view = mapView.view(for: annotation) else { return }
            view.image = pinImage(accent: accent, outline: outline)
            view.centerOffset = Self.pinCenterOffset(for: view.image)
        }

        /// 针尖 = glyph 底边中点，落在画布「中心 + 半针高 − 下边距」处。
        /// `MKAnnotationView` 默认拿图片**中心**对齐坐标点，
        /// 把视图上移这段距离，针尖才正扎在目标坐标上
        ///（与旧 overlay 版 2026-10-14 实测定稿的补偿同一套几何）。
        private static func pinCenterOffset(for image: UIImage?) -> CGPoint {
            guard let image else { return .zero }
            return CGPoint(x: 0, y: -(image.size.height / 2 - pinCanvasMargin))
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }

            // 选点针：身份比对（圆点与针都是 MKPointAnnotation，只能认实例）。
            if annotation === targetAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Self.targetPinReuseIdentifier
                ) ?? MKAnnotationView(annotation: annotation,
                                      reuseIdentifier: Self.targetPinReuseIdentifier)
                view.annotation = annotation
                view.image = pinImage(accent: parent.accentColor, outline: parent.pinOutlineColor)
                view.canShowCallout = false
                view.centerOffset = Self.pinCenterOffset(for: view.image)
                // 改写目标点压在实时圆点上方：重叠时针在上，针尖落点不被圆点吃掉。
                view.displayPriority = .defaultHigh
                return view
            }

            // 其余只有实时位置圆点一种。
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: Self.realLocationReuseIdentifier
            ) ?? MKAnnotationView(annotation: annotation,
                                  reuseIdentifier: Self.realLocationReuseIdentifier)

            view.annotation = annotation
            view.image = realLocationDot(accent: parent.accentColor)
            view.canShowCallout = false
            // 圆点要正对坐标点。`MKAnnotationView` 默认按图片中心对齐，
            // 但显式写出来可以防止将来有人把它换成带尖角的大头针图片时忘记改。
            view.centerOffset = .zero
            return view
        }
    }
}

// MARK: - 容差比较

extension MKCoordinateRegion {

    /// 两个 region 是否「基本上就是同一个」。
    ///
    /// 容差 `1e-6` 度约合 0.1 米 —— 比任何有意义的差别都小，
    /// 又足以吸收浮点误差。`updateUIView` 靠它判断该不该移动地图：
    /// 判宽了会误把地图拽回去，判严了（比如用 `==`）会在每次重算时都多设一次 region。
    func isNearlyEqual(to other: MKCoordinateRegion) -> Bool {
        abs(center.latitude - other.center.latitude) < 1e-6
            && abs(center.longitude - other.center.longitude) < 1e-6
            && abs(span.latitudeDelta - other.span.latitudeDelta) < 1e-6
            && abs(span.longitudeDelta - other.span.longitudeDelta) < 1e-6
    }
}

extension CLLocationCoordinate2D {

    /// 同上，用于真实位置圆点的原地更新。
    func isNearlyEqual(to other: CLLocationCoordinate2D) -> Bool {
        abs(latitude - other.latitude) < 1e-6
            && abs(longitude - other.longitude) < 1e-6
    }
}

// MARK: - 图层

/// 地图图层。
///
/// 三项与上一代实现的图层菜单**完全一致** —— 它的本地化文件里就是
/// `图层` / `标准` / `卫星` / `混合` 这四个词，所以这不是新设计，是沿用。
enum MapLayerKind: String, CaseIterable, Identifiable {

    case standard
    case satellite
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return AppLocalization.string("标准")
        case .satellite: return AppLocalization.string("卫星")
        case .hybrid: return AppLocalization.string("混合")
        }
    }

    /// 菜单里每项前面那个小图标。
    ///
    /// **不能用 `map` / `globe` 之外的第三方符号** —— 这几个都要能追溯到 iOS 15，
    /// 否则旧系统上会渲染成一个空白方块。
    var systemImage: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe.americas.fill"
        case .hybrid: return "square.stack.3d.up"
        }
    }

    var mapType: MKMapType {
        switch self {
        case .standard: return .standard
        case .satellite: return .satellite
        case .hybrid: return .hybrid
        }
    }
}
