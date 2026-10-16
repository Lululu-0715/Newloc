import SwiftUI

/// 状态胶囊的语义色。
///
/// **原样沿用上一版**（用户明确要求不改）：未验证灰 / 验证中蓝 / 已生效绿 / 未生效橙。
///
/// 底色取色值的 14% —— 这个比例是上一版实测调出来的：
/// 再淡看不出色块，再浓就开始吃文字对比度。
///
/// 黑白主题下这四颗色点是界面里**唯一**的彩色，反而比彩色主题下更醒目：
/// 扫一眼就知道生没生效，而不用去读文字。
enum StatusTint: Equatable {
    case idle
    case verifying
    case effective
    case ineffective

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .verifying: return .blue
        case .effective: return .green
        case .ineffective: return .orange
        }
    }

    static let fillOpacity: Double = 0.14
}

/// 状态胶囊：带判定含义（有语义色）。
struct StatusPill: View {

    let text: String
    let tint: StatusTint
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.app(10, weight: .semibold))
            }
            Text(text)
                .font(.app(11, weight: .medium))
        }
        .foregroundStyle(tint.color)
        .padding(.horizontal, 9)
        .frame(height: Tokens.Size.pill)
        .background(tint.color.opacity(StatusTint.fillOpacity), in: Capsule())
    }
}

/// 中性胶囊：只陈述事实，不带判定（例如「内置代理」「证书已信任」）。
///
/// 和 `StatusPill` 分开是刻意的：这两类信息混用同一个组件，
/// 会让「有颜色 = 有结论」这条视觉规则失效。
struct NeutralPill: View {

    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.app(10, weight: .semibold))
            }
            Text(text)
                .font(.app(11, weight: .medium))
        }
        .foregroundStyle(Color.ncTextSecondary)
        .padding(.horizontal, 9)
        .frame(height: Tokens.Size.pill)
        .background(Color.primary.opacity(Tokens.Glass.neutralCapsule), in: Capsule())
    }
}
