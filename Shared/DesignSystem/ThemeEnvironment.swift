import SwiftUI

/// 把当前主题注入环境。
///
/// 挂在根视图上一次即可，之后所有子视图通过
/// `@Environment(\.themeAccent)` / `@Environment(\.themeOnAccent)` 取值。
///
/// **为什么不用 `@ObservedObject ThemeStore.shared` 到处读**：
/// 那样每个视图都会因为「任何主题变化」重新求值；走环境值的话，
/// 值一变只有真正读了它的视图重新求值，代价小得多。
private struct ThemeEnvironmentModifier: ViewModifier {

    @StateObject private var themeStore = ThemeStore.shared

    func body(content: Content) -> some View {
        content
            .environment(\.themeAccent, themeStore.theme.accent)
            .environment(\.themeOnAccent, themeStore.theme.onPrimaryAction)
            .tint(themeStore.theme.accent)
    }
}

extension View {

    /// 注入主题环境。挂在根视图（或每个独立预览）上。
    func withThemeEnvironment() -> some View {
        modifier(ThemeEnvironmentModifier())
    }
}
