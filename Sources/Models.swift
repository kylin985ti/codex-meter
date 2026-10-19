import Foundation

struct TokenBreakdown: Equatable {
    var inputTokens: Int64
    var cachedInputTokens: Int64
    var outputTokens: Int64
    var reasoningOutputTokens: Int64
    var totalTokens: Int64

    static let zero = TokenBreakdown(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    func delta(from previous: TokenBreakdown?) -> TokenBreakdown {
        guard let previous else { return self }

        func component(_ current: Int64, _ old: Int64) -> Int64 {
            current >= old ? current - old : current
        }

        return TokenBreakdown(
            inputTokens: component(inputTokens, previous.inputTokens),
            cachedInputTokens: component(cachedInputTokens, previous.cachedInputTokens),
            outputTokens: component(outputTokens, previous.outputTokens),
            reasoningOutputTokens: component(reasoningOutputTokens, previous.reasoningOutputTokens),
            totalTokens: component(totalTokens, previous.totalTokens)
        )
    }

    static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }
}

struct RateLimitWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

struct CreditInfo: Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct RateLimitSnapshot: Equatable {
    let limitID: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditInfo?
    let planType: String?
    let reachedType: String?
}

struct AccountUsage: Equatable {
    let todayTokens: Int64?
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
}

enum UsageOrigin: String {
    case official = "官方 App Server"
    case officialCache = "官方上次成功数据"
    case localLogs = "本机日志估算"
    case ollamaOfficial = "Ollama 官方接口"
    case unavailable = "暂无数据"
}

struct RateLimitSelection {
    let snapshot: RateLimitSnapshot?
    let origin: UsageOrigin

    static func preferOfficial(
        current: RateLimitSnapshot?,
        cached: RateLimitSnapshot?
    ) -> RateLimitSelection {
        if let current {
            return RateLimitSelection(snapshot: current, origin: .official)
        }
        if let cached {
            return RateLimitSelection(snapshot: cached, origin: .officialCache)
        }
        return RateLimitSelection(snapshot: nil, origin: .unavailable)
    }
}

struct OllamaSnapshot: Equatable {
    let session: RateLimitWindow?
    let weekly: RateLimitWindow?
    let purchasedUSD: Double?
    let requests24h: Int?
    let requests7d: Int?
    let origin: UsageOrigin
    let note: String?

    var hasWindows: Bool {
        session != nil || weekly != nil
    }

    static let unavailable = OllamaSnapshot(
        session: nil,
        weekly: nil,
        purchasedUSD: nil,
        requests24h: nil,
        requests7d: nil,
        origin: .unavailable,
        note: nil
    )
}

struct UsageSnapshot: Equatable {
    var rateLimits: RateLimitSnapshot?
    var todayTokens: Int64?
    var todayBreakdown: TokenBreakdown?
    var lifetimeTokens: Int64?
    var rateOrigin: UsageOrigin
    var tokenOrigin: UsageOrigin
    var ollama: OllamaSnapshot?
    var updatedAt: Date
    var note: String?

    static let loading = UsageSnapshot(
        rateLimits: nil,
        todayTokens: nil,
        todayBreakdown: nil,
        lifetimeTokens: nil,
        rateOrigin: .unavailable,
        tokenOrigin: .unavailable,
        ollama: nil,
        updatedAt: Date(),
        note: nil
    )

    var headlineRemainingPercent: Double? {
        rateLimits?.primary?.remainingPercent
    }
}

struct LocalScanResult {
    let today: TokenBreakdown
    let rateLimits: RateLimitSnapshot?
    let matchedEvents: Int
    let filesScanned: Int
}

enum MeterFormat {
    static func compactTokens(_ value: Int64?) -> String {
        guard let value else { return "--" }
        let absolute = Double(abs(value))
        let sign = value < 0 ? "-" : ""

        if absolute >= 1_000_000_000 {
            return sign + compact(absolute / 1_000_000_000) + "B"
        }
        if absolute >= 1_000_000 {
            return sign + compact(absolute / 1_000_000) + "M"
        }
        if absolute >= 1_000 {
            return sign + compact(absolute / 1_000) + "K"
        }
        return String(value)
    }

    static func exactTokens(_ value: Int64?) -> String {
        guard let value else { return "暂无数据" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f%%", value)
    }

    static func windowName(minutes: Int) -> String {
        if minutes % 10_080 == 0 {
            let weeks = minutes / 10_080
            return weeks == 1 ? "7 天额度" : "\(weeks) 周额度"
        }
        if minutes % 1_440 == 0 {
            return "\(minutes / 1_440) 天额度"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60) 小时额度"
        }
        return "\(minutes) 分钟额度"
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "重置时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current

        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm 重置"
        } else if Calendar.current.isDateInTomorrow(date) {
            formatter.dateFormat = "明天 HH:mm 重置"
        } else {
            formatter.dateFormat = "M月d日 HH:mm 重置"
        }
        return formatter.string(from: date)
    }

    static func updatedText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func compact(_ value: Double) -> String {
        if value >= 100 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }
}
