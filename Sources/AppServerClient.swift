import Foundation

struct AppServerFetchResult {
    let rateLimits: RateLimitSnapshot?
    let usage: AccountUsage?
    let executablePath: String?
    let usageEndpointSupported: Bool
    let diagnostic: String?
}

final class AppServerClient {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    func fetch() -> AppServerFetchResult {
        guard let executable = CodexExecutableLocator.find() else {
            return AppServerFetchResult(
                rateLimits: nil,
                usage: nil,
                executablePath: nil,
                usageEndpointSupported: false,
                diagnostic: "未找到 Codex CLI"
            )
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let stateQueue = DispatchQueue(label: "com.codexmeter.appserver.responses")
        let completed = DispatchSemaphore(value: 0)
        var buffer = Data()
        var responses: [Int: [String: Any]] = [:]
        var didSendAccountRequests = false
        var didSignal = false

        func signalOnce() {
            guard !didSignal else { return }
            didSignal = true
            completed.signal()
        }

        func writeMessage(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            var line = data
            line.append(0x0A)
            try? inputPipe.fileHandleForWriting.write(contentsOf: line)
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            stateQueue.async {
                if data.isEmpty {
                    signalOnce()
                    return
                }

                buffer.append(data)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newlineIndex])
                    buffer.removeSubrange(...newlineIndex)
                    guard
                        !line.isEmpty,
                        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                        let id = AppServerClient.intValue(object["id"])
                    else { continue }

                    if id == 1, !didSendAccountRequests {
                        didSendAccountRequests = true
                        writeMessage(["method": "initialized"])
                        writeMessage(["id": 2, "method": "account/rateLimits/read"])
                        writeMessage(["id": 3, "method": "account/usage/read"])
                        continue
                    }

                    if id == 2 || id == 3 {
                        responses[id] = object
                    }
                    if responses[2] != nil, responses[3] != nil {
                        signalOnce()
                    }
                }
            }
        }

        process.terminationHandler = { _ in
            stateQueue.async {
                signalOnce()
            }
        }

        do {
            try process.run()
            writeMessage([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-meter",
                        "version": "1.1.1"
                    ]
                ]
            ])
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return AppServerFetchResult(
                rateLimits: nil,
                usage: nil,
                executablePath: executable,
                usageEndpointSupported: false,
                diagnostic: "无法启动 Codex App Server：\(error.localizedDescription)"
            )
        }

        let waitResult = completed.wait(timeout: .now() + timeout)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }

        let captured = stateQueue.sync { responses }
        let rateLimits = captured[2].flatMap(Self.parseRateLimits)
        let usage = captured[3].flatMap(Self.parseUsage)
        let usageSupported = captured[3]?["result"] != nil

        var diagnostic: String?
        if waitResult == .timedOut {
            diagnostic = "Codex App Server 响应超时"
        } else if rateLimits == nil {
            diagnostic = Self.errorMessage(from: captured[2]) ?? "未取得官方额度"
        }

        return AppServerFetchResult(
            rateLimits: rateLimits,
            usage: usage,
            executablePath: executable,
            usageEndpointSupported: usageSupported,
            diagnostic: diagnostic
        )
    }

    private static func parseRateLimits(_ message: [String: Any]) -> RateLimitSnapshot? {
        guard
            let result = message["result"] as? [String: Any],
            let raw = result["rateLimits"] as? [String: Any]
        else { return nil }

        return RateLimitSnapshot(
            limitID: raw["limitId"] as? String,
            limitName: raw["limitName"] as? String,
            primary: parseWindow(raw["primary"]),
            secondary: parseWindow(raw["secondary"]),
            credits: parseCredits(raw["credits"]),
            planType: raw["planType"] as? String,
            reachedType: raw["rateLimitReachedType"] as? String
        )
    }

    private static func parseUsage(_ message: [String: Any]) -> AccountUsage? {
        guard let result = message["result"] as? [String: Any] else { return nil }

        let todayKey = dateKey(Date())
        var todayTokens: Int64?
        if let buckets = result["dailyUsageBuckets"] as? [[String: Any]] {
            for bucket in buckets where bucket["startDate"] as? String == todayKey {
                todayTokens = int64Value(bucket["tokens"])
                break
            }
        }

        let summary = result["summary"] as? [String: Any]
        return AccountUsage(
            todayTokens: todayTokens,
            lifetimeTokens: int64Value(summary?["lifetimeTokens"]),
            peakDailyTokens: int64Value(summary?["peakDailyTokens"])
        )
    }

    private static func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let raw = value as? [String: Any] else { return nil }
        guard
            let usedPercent = doubleValue(raw["usedPercent"]),
            let minutes = intValue(raw["windowDurationMins"])
        else { return nil }

        let resetSeconds = doubleValue(raw["resetsAt"])
        return RateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: minutes,
            resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func parseCredits(_ value: Any?) -> CreditInfo? {
        guard let raw = value as? [String: Any] else { return nil }
        let hasCredits = boolValue(raw["hasCredits"]) ?? false
        let unlimited = boolValue(raw["unlimited"]) ?? false
        let balance: String?
        if let string = raw["balance"] as? String {
            balance = string
        } else if let number = raw["balance"] as? NSNumber {
            balance = number.stringValue
        } else {
            balance = nil
        }
        return CreditInfo(hasCredits: hasCredits, unlimited: unlimited, balance: balance)
    }

    private static func errorMessage(from message: [String: Any]?) -> String? {
        guard let error = message?["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    private static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func int64Value(_ value: Any?) -> Int64? {
        if let int = value as? Int64 { return int }
        if let int = value as? Int { return Int64(int) }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["true", "1", "yes"].contains(string.lowercased())
        }
        return nil
    }
}

enum CodexExecutableLocator {
    static func find() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates: [String] = []

        if let override = ProcessInfo.processInfo.environment["CODEX_METER_CODEX_PATH"] {
            candidates.append(override)
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        candidates.append(contentsOf: [
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/Library/pnpm/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
