import SwiftUI
import MapKit

/// 收藏夹列表：内层小卡右侧那颗书签圆钮的落点。
///
/// 点某一行 = 把地图挪到那个点并关掉列表（该点随即成为当前目标点，
/// 坐标下发走主卡片同一套换算）。左滑删除。
struct FavoritesView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SavedPlacesStore.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    /// 选中某个收藏后把地图挪过去。由主界面注入（地图 region 归它管）。
    var onPick: (SavedPlace) -> Void

    /// 正在重命名的收藏（`sheet(item:)` 用）。nil = 弹窗关闭。
    @State private var renamingPlace: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        ZStack {
            // 2026-10-14 补：此前这一页是全工程**唯一**没有主题背景的页面
            // （设置 / 主题 / 手册 / 代理 / 欢迎 / 诊断 / 第三方都有），
            // 配色主题换成彩色后这里还是死灰底 —— 用户实测「收藏页怎么没有
            // 配色渲染」。补上后与其余页面同一张脸。
            ThemedBackground()

            Group {
                if store.places.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .navigationTitle(AppLocalization.string("收藏位置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalization.string("完成")) { dismiss() }
            }
        }
        .sheet(item: $renamingPlace) { place in
            RenameSheet(
                initialName: renameText,
                accent: themeStore.accent,
                onSave: { newName in
                    store.rename(place, to: newName)
                    renamingPlace = nil
                },
                onCancel: { renamingPlace = nil }
            )
        }
    }

    private var list: some View {
        List {
            ForEach(store.places) { place in
                Button {
                    onPick(place)
                    dismiss()
                } label: {
                    // ⚠️ 必须撑满行宽 —— contentShape 的命中区跟着这个容器走，
                    // 只包文字的话，行右侧空白点了没反应（2026-10-12 用户实测反馈）。
                    VStack(alignment: .leading, spacing: 3) {
                        Text(place.name.isEmpty
                             ? AppLocalization.string("未命名位置")
                             : place.name)
                            .font(.app(15, weight: .medium))
                            .foregroundStyle(Color.ncText)

                        Text(CoordinateConverter.text(place.coordinate))
                            .font(.app(12).monospaced())
                            .foregroundStyle(Color.ncTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 左滑 = 重命名（右滑保留系统删除）。
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        renameText = place.name
                        renamingPlace = place
                    } label: {
                        Label(AppLocalization.string("重命名"), systemImage: "pencil")
                    }
                    .tint(themeStore.accent)
                }
            }
            .onDelete { store.remove(atOffsets: $0) }
        }
        .listStyle(.insetGrouped)
        // 露出后面的主题背景。`.scrollContentBackground` 是 iOS 16+，
        // 部署目标 15.0 所以要走分叉；iOS 15 上保持系统分组底色（不露
        // 主题渐变，但行内容与可读性不受影响）。
        .appTransparentListBackground()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bookmark")
                .font(.app(36))
                .foregroundStyle(Color.ncTextTertiary)

            Text(AppLocalization.string("暂无收藏"))
                .font(.app(16, weight: .medium))
                .foregroundStyle(Color.ncText)

            Text(AppLocalization.string("在地图上选好点，点地名旁的星标即可收藏"))
                .font(.app(13))
                .foregroundStyle(Color.ncTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Tokens.Spacing.page)
    }
}

/// 让 List 的背景透明、露出后面的主题背景。
///
/// `.scrollContentBackground(.hidden)` 是 **iOS 16+**，而本工程部署目标是
/// 15.0 —— 老系统上没有等价的安全写法（`UITableView.appearance()` 是全局
/// 副作用，会连累别的列表），所以走分叉：老系统保持系统分组底色。
private extension View {

    @ViewBuilder
    func appTransparentListBackground() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

/// 重命名弹窗。iOS 15 的 `.alert` 放不了 TextField，所以用轻量 sheet。
private struct RenameSheet: View {

    @State private var name: String
    let accent: Color
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    init(initialName: String, accent: Color,
         onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        _name = State(initialValue: initialName)
        self.accent = accent
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(AppLocalization.string("名称"))) {
                    TextField(AppLocalization.string("未命名位置"), text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { onSave(name) }
                }
            }
            .navigationTitle(AppLocalization.string("重命名"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("取消")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("确定")) { onSave(name) }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { focused = true }
    }
}
