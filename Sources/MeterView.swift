import AppKit
import SwiftUI

enum MeterPresentation {
    case popover
    case desktop
}

struct MeterActions {
    let toggleDesktop: () -> Void
    let openUsagePage: () -> Void
    let quit: () -> Void
}

struct MeterView: View {
    @ObservedObject var store: UsageStore
    let presentation: MeterPresentation
    let actions: MeterActions

    private var width: CGFloat { presentation == .desktop ? 368 : 392 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(0.10),
                            Color.indigo.opacity(0.035),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)

            VStack(spacing: 11) {
                header
                codexHeader
                quotaSection
                todaySection
                sourceSection
                actionRow
            }
            .padding(16)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .padding(presentation == .desktop ? 8 : 0)
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan, Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Meter")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("Codex 额度与 Token")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: store.refresh) {
                Group {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(MeterIconButtonStyle())
            .help("立即刷新")

            if presentation == .desktop {
                Button(action: actions.toggleDesktop) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(MeterIconButtonStyle())
                .help("隐藏桌面卡片")
            }
        }
    }

    private var codexHeader: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.cyan.gradient)
                .frame(width: 7, height: 7)
            Text("CODEX")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            if let plan = store.snapshot.rateLimits?.planType, !plan.isEmpty {
                Text(plan.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.cyan.opacity(0.12), in: Capsule())
            }
            Spacer()
            SourcePill(label: "额度", origin: store.snapshot.rateOrigin)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var quotaSection: some View {
        if let rateLimits = store.snapshot.rateLimits,
           rateLimits.primary != nil || rateLimits.secondary != nil {
            HStack(spacing: 10) {
                if let primary = rateLimits.primary {
                    QuotaWindowCard(window: primary)
                }
                if let secondary = rateLimits.secondary {
                    QuotaWindowCard(window: secondary)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 25))
                    .foregroundStyle(.secondary)
                Text(store.isRefreshing ? "正在读取额度…" : "暂未取得额度")
                    .font(.system(size: 13, weight: .medium))
                Text("请确认 Codex CLI 已登录，然后刷新")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(MeterSurface())
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.snapshot.tokenOrigin == .official ? "账号今日 Token 活动" : "今天使用（本机）")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(MeterFormat.compactTokens(store.snapshot.todayTokens))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(MeterFormat.exactTokens(store.snapshot.todayTokens) + " tokens")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan, Color.indigo],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            if let breakdown = store.snapshot.todayBreakdown {
                HStack(spacing: 8) {
                    TokenStat(label: "输入", value: breakdown.inputTokens)
                    TokenStat(label: "输出", value: breakdown.outputTokens)
                    TokenStat(label: "缓存输入", value: breakdown.cachedInputTokens)
                }
                .help("缓存输入包含在输入 Token 内；推理 Token 包含在输出 Token 内")
            } else if let lifetime = store.snapshot.lifetimeTokens {
                HStack {
                    Label("累计", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(MeterFormat.exactTokens(lifetime))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
        }
        .padding(14)
        .background(MeterSurface())
        .help(store.snapshot.tokenOrigin == .official
              ? "官方接口返回账号 Token 活动；日期桶时区由 Codex 服务决定"
              : "仅估算本机今日写入 Codex 日志的 Token，不包含其他设备或未落地的云任务")
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SourcePill(label: "Codex Token", origin: store.snapshot.tokenOrigin)
                Spacer()
                Text("更新于 " + MeterFormat.updatedText(store.snapshot.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if let note = store.snapshot.note {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if presentation == .popover {
                Button(action: actions.toggleDesktop) {
                    Label("桌面卡片", systemImage: "rectangle.on.rectangle")
                }
            }
            Button(action: actions.openUsagePage) {
                Label("Codex 用量", systemImage: "arrow.up.right.square")
            }
            Spacer()
            if presentation == .popover {
                Button(action: actions.quit) {
                    Image(systemName: "power")
                }
                .help("退出 Codex Meter")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(MeterActionButtonStyle())
    }
}

private struct QuotaWindowCard: View {
    let window: RateLimitWindow

    private var color: Color {
        if window.remainingPercent > 50 { return .mint }
        if window.remainingPercent > 20 { return .orange }
        return .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MeterFormat.windowName(minutes: window.windowMinutes))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(MeterFormat.percent(window.remainingPercent))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("剩余")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: proxy.size.width * window.remainingPercent / 100)
                }
            }
            .frame(height: 6)
            Text(MeterFormat.resetText(window.resetsAt))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(MeterSurface())
    }
}

private struct TokenStat: View {
    let label: String
    let value: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            Text(MeterFormat.compactTokens(value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct SourcePill: View {
    let label: String
    let origin: UsageOrigin

    private var color: Color {
        switch origin {
        case .official: return .mint
        case .officialCache: return .orange
        case .localLogs: return .orange
        case .unavailable: return .secondary
        }
    }

    private var shortOrigin: String {
        switch origin {
        case .official: return "官方"
        case .officialCache: return "官方缓存"
        case .localLogs: return "本机估算"
        case .unavailable: return "暂无"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(label) · \(shortOrigin)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .help(origin.rawValue)
    }
}

private struct MeterSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

private struct MeterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055))
            )
            .contentShape(Circle())
    }
}

private struct MeterActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(configuration.isPressed ? Color.primary.opacity(0.6) : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.11 : 0.055))
            )
    }
}
