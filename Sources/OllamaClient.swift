import Foundation

// Ollama Cloud 用量读取。
// 线上接口与官方文档存在偏差，因此所有字段都按可选解析：
//   GET https://ollama.com/api/balance
//     {"included":{"session":{"remaining_percent":98.93,"resets_at":"..."},
//                  "weekly":{"remaining_percent":97.75,"resets_at":"..."}},
//      "purchased":{"balance_usd":0}}
//   GET https://ollama.com/api/usage?range=24h|7d|30d&scope=self
//     {"totals":{"request_count":587},"buckets":[...]}
struct OllamaFetchResult {
    let session: RateLimitWindow?
    let weekly: RateLimitWindow?
    let purchasedUSD: Double?
    let requests24h: Int?
    let requests7d: Int?
    let diagnostic: String?
}

final class OllamaClient: @unchecked Sendable {
    private let timeout: TimeInterval
    private let session: URLSession

    // balance 只返回 remaining_percent 与 resets_at，不含窗口长度。
    // 下面两个常量按实测的重置节奏推定（session 在 5 小时后的整点重置，weekly 在周一 00:00 重置），
    // 仅影响卡片标题文字，不参与额度计算。
    static let sessionWindowMinutes = 5 * 60
    static let weeklyWindowMinutes = 7 * 24 * 60

    private static let balanceURL = URL(string: "https://ollama.com/api/balance")
    private static let usageURL = URL(string: "https://ollama.com/api/usage?range=24h&scope=self")
    private static let weeklyUsageURL = URL(string: "https://ollama.com/api/usage?range=7d&scope=self")

    init(timeout: TimeInterval = 12) {
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func fetch() -> OllamaFetchResult {
        guard let key = OllamaKeyStore.resolve() else {
            return OllamaFetchResult(
                session: nil,
                weekly: nil,
                purchasedUSD: nil,
                requests24h: nil,
                requests7d: nil,
                diagnostic: "未找到 Ollama API Key"
            )
        }

        let balance = getJSON(Self.balanceURL, key: key)
        var sessionWindow: RateLimitWindow?
        var weeklyWindow: RateLimitWindow?
        var purchased: Double?

        if let payload = balance.payload {
            let included = payload["included"] as? [String: Any]
            sessionWindow = Self.parseWindow(
                included?["session"],
                minutes: Self.sessionWindowMinutes,
                fallbackPeriod: nil
            )
            weeklyWindow = Self.parseWindow(
                included?["weekly"],
                minutes: Self.weeklyWindowMinutes,
                fallbackPeriod: nil
            )
            // 付费套餐/其它账号形态可能返回文档里的 allowance 结构，做一次兼容。
            if sessionWindow == nil && weeklyWindow == nil, let included {
                sessionWindow = Self.parseAllowanceWindow(included, minutes: Self.weeklyWindowMinutes)
            }
            purchased = Self.doubleValue((payload["purchased"] as? [String: Any])?["balance_usd"])
        }

        let usage = usageCounts(key: key)
        let requests24h = usage.requests24h
        let requests7d = usage.requests7d

        var diagnostic: String?
        if let error = balance.error {
            diagnostic = error
        } else if sessionWindow == nil && weeklyWindow == nil {
            diagnostic = "Ollama 额度字段无法解析"
        }

        return OllamaFetchResult(
            session: sessionWindow,
            weekly: weeklyWindow,
            purchasedUSD: purchased,
            requests24h: requests24h,
            requests7d: requests7d,
            diagnostic: diagnostic
        )
    }

    private struct HTTPResult {
        let payload: [String: Any]?
        let error: String?
    }

    // 请求次数变化很慢，而额度需要每次刷新都保持最新；
    // 这里只缓存 usage 的两个查询，把每轮 3 个请求降到通常 1 个。
    private struct UsageCounts {
        let requests24h: Int?
        let requests7d: Int?
    }

    private static let usageCacheLifetime: TimeInterval = 300
    private let cacheLock = NSLock()
    private var cachedUsage: (counts: UsageCounts, at: Date)?

    private func usageCounts(key: String) -> UsageCounts {
        cacheLock.lock()
        if let cached = cachedUsage, Date().timeIntervalSince(cached.at) < Self.usageCacheLifetime {
            cacheLock.unlock()
            return cached.counts
        }
        cacheLock.unlock()

        let counts = UsageCounts(
            requests24h: requestCount(Self.usageURL, key: key),
            requests7d: requestCount(Self.weeklyUsageURL, key: key)
        )

        cacheLock.lock()
        cachedUsage = (counts, Date())
        cacheLock.unlock()
        return counts
    }

    private func requestCount(_ url: URL?, key: String) -> Int? {
        guard let payload = getJSON(url, key: key).payload else { return nil }
        return Self.intValue((payload["totals"] as? [String: Any])?["request_count"])
    }

    private func getJSON(_ url: URL?, key: String) -> HTTPResult {
        guard let url else { return HTTPResult(payload: nil, error: "接口地址无效") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var outcome = HTTPResult(payload: nil, error: "请求未完成")

        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            let resolved: HTTPResult
            if let error {
                resolved = HTTPResult(payload: nil, error: Self.describe(error))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 401 {
                    resolved = HTTPResult(payload: nil, error: "Ollama API Key 无效或已过期")
                } else {
                    resolved = HTTPResult(payload: nil, error: "Ollama 接口返回 HTTP \(http.statusCode)")
                }
            } else if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let message = object["error"] as? String {
                    resolved = HTTPResult(payload: nil, error: "Ollama：\(message)")
                } else {
                    resolved = HTTPResult(payload: object, error: nil)
                }
            } else {
                resolved = HTTPResult(payload: nil, error: "Ollama 返回内容无法解析")
            }
            lock.lock()
            outcome = resolved
            lock.unlock()
        }.resume()

        _ = semaphore.wait(timeout: .now() + timeout + 2)
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "Ollama 网络不可用"
        case NSURLErrorTimedOut:
            return "Ollama 接口响应超时"
        default:
            return "Ollama 请求失败：\(nsError.localizedDescription)"
        }
    }

    // 线上形态：{"remaining_percent":98.93,"resets_at":"..."}
    private static func parseWindow(
        _ value: Any?,
        minutes: Int,
        fallbackPeriod: [String: Any]?
    ) -> RateLimitWindow? {
        guard let raw = value as? [String: Any] else { return nil }

        let remaining = doubleValue(raw["remaining_percent"])
            ?? doubleValue(raw["remainingPercent"]).map { $0 <= 1 ? $0 * 100 : $0 }

        guard let remaining else { return nil }

        let resets = parseISO8601(raw["resets_at"] as? String)
            ?? parseISO8601(raw["resetsAt"] as? String)
            ?? parseISO8601(fallbackPeriod?["until"] as? String)

        return RateLimitWindow(
            usedPercent: min(100, max(0, 100 - remaining)),
            windowMinutes: minutes,
            resetsAt: resets
        )
    }

    // 文档形态：{"balance_usd":72.5,"allowance_usd":100,"period":{"until":"..."}}
    private static func parseAllowanceWindow(
        _ included: [String: Any],
        minutes: Int
    ) -> RateLimitWindow? {
        guard
            let allowance = doubleValue(included["allowance_usd"]),
            allowance > 0,
            let balance = doubleValue(included["balance_usd"])
        else { return nil }

        let period = included["period"] as? [String: Any]
        return RateLimitWindow(
            usedPercent: min(100, max(0, 100 - balance / allowance * 100)),
            windowMinutes: minutes,
            resetsAt: parseISO8601(period?["until"] as? String)
        )
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        // 线上 from/until 可能出现 8 位小数秒，截断到 3 位再解析。
        if let dot = value.firstIndex(of: "."), let timezone = value.lastIndex(where: { $0 == "Z" || $0 == "+" }) {
            let head = String(value[value.startIndex..<dot])
            let fraction = String(value[value.index(after: dot)..<timezone].prefix(3))
            if let date = fractional.date(from: "\(head).\(fraction)Z") { return date }
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

// API Key 解析顺序：进程环境变量 → DSH 的 ~/.dsh/.env → 工具自己的配置文件。
enum OllamaKeyStore {
    static func resolve() -> String? {
        if let key = cleaned(ProcessInfo.processInfo.environment["OLLAMA_API_KEY"]) {
            return key
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        if let envFile = try? String(contentsOf: home.appendingPathComponent(".dsh/.env"), encoding: .utf8),
           let key = keyFromEnvFile(envFile) {
            return key
        }

        if let data = try? Data(contentsOf: home.appendingPathComponent(".codexmeter/config.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = cleaned(object["ollamaApiKey"] as? String) {
            return key
        }

        return nil
    }

    private static func keyFromEnvFile(_ contents: String) -> String? {
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("OLLAMA_API_KEY=") else { continue }
            let value = trimmed.dropFirst("OLLAMA_API_KEY=".count)
            return cleaned(String(value))
        }
        return nil
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("export ") {
            result = String(result.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
        }
        if result.count >= 2,
           (result.hasPrefix("\"") && result.hasSuffix("\"")) || (result.hasPrefix("'") && result.hasSuffix("'")) {
            result = String(result.dropFirst().dropLast())
        }
        return result.isEmpty ? nil : result
    }
}
