import Foundation

final class LocalTokenScanner {
    private struct TokenEvent {
        let sessionID: String
        let timestamp: Date
        let total: TokenBreakdown?
        let last: TokenBreakdown?
        let rateLimits: RateLimitSnapshot?
    }

    private let fileManager: FileManager
    private let roots: [URL]
    private let isoWithFractional: ISO8601DateFormatter
    private let isoWithoutFractional: ISO8601DateFormatter

    init(fileManager: FileManager = .default, roots: [URL]? = nil) {
        self.fileManager = fileManager
        if let roots {
            self.roots = roots
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            self.roots = [
                home.appendingPathComponent(".codex/sessions", isDirectory: true),
                home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
            ]
        }
        isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoWithoutFractional = ISO8601DateFormatter()
        isoWithoutFractional.formatOptions = [.withInternetDateTime]
    }

    func scanToday(referenceDate: Date = Date()) -> LocalScanResult {
        let files = candidateFiles(referenceDate: referenceDate)
        guard !files.isEmpty else {
            return LocalScanResult(
                today: .zero,
                rateLimits: nil,
                matchedEvents: 0,
                filesScanned: 0
            )
        }

        let events = extractWithRipgrep(files: files) ?? extractNatively(files: files)
        return aggregate(events: events, referenceDate: referenceDate, filesScanned: files.count)
    }

    private func candidateFiles(referenceDate: Date) -> [String] {
        let startOfToday = Calendar.current.startOfDay(for: referenceDate)
        let recentFloor = Calendar.current.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var files: [String] = []

        for root in roots where fileManager.isReadableFile(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                guard values.isRegularFile == true else { continue }
                guard let modified = values.contentModificationDate, modified >= recentFloor else { continue }
                files.append(url.path)
            }
        }
        return files.sorted()
    }

    private func extractWithRipgrep(files: [String]) -> [TokenEvent]? {
        guard let ripgrep = RipgrepLocator.find(fileManager: fileManager) else { return nil }
        var allEvents: [TokenEvent] = []

        for batchStart in stride(from: 0, to: files.count, by: 150) {
            let batchEnd = min(batchStart + 150, files.count)
            let batch = Array(files[batchStart..<batchEnd])
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: ripgrep)
            process.arguments = [
                "--json",
                "--fixed-strings",
                "--no-messages",
                "\"type\":\"token_count\""
            ] + batch
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus > 1 { return nil }
                allEvents.append(contentsOf: parseRipgrepOutput(data))
            } catch {
                return nil
            }
        }
        return allEvents
    }

    private func parseRipgrepOutput(_ data: Data) -> [TokenEvent] {
        var events: [TokenEvent] = []
        for rawLine in data.split(separator: 0x0A) {
            guard
                let envelope = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                envelope["type"] as? String == "match",
                let payload = envelope["data"] as? [String: Any],
                let pathInfo = payload["path"] as? [String: Any],
                let path = pathInfo["text"] as? String,
                let linesInfo = payload["lines"] as? [String: Any],
                let text = linesInfo["text"] as? String,
                let event = parseEvent(data: Data(text.utf8), path: path)
            else { continue }
            events.append(event)
        }
        return events
    }

    private func extractNatively(files: [String]) -> [TokenEvent] {
        var events: [TokenEvent] = []
        let needle = Data("\"type\":\"token_count\"".utf8)
        let maxLineBytes = 512 * 1024

        for path in files {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { continue }
            defer { try? handle.close() }
            var lineBuffer = Data()

            while true {
                let nextChunk: Data?
                do {
                    nextChunk = try handle.read(upToCount: 128 * 1024)
                } catch {
                    nextChunk = nil
                }
                guard let chunk = nextChunk, !chunk.isEmpty else {
                    if lineBuffer.range(of: needle) != nil,
                       let event = parseEvent(data: lineBuffer, path: path) {
                        events.append(event)
                    }
                    break
                }

                let parts = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
                for (index, part) in parts.enumerated() {
                    if lineBuffer.count < maxLineBytes {
                        let remaining = maxLineBytes - lineBuffer.count
                        lineBuffer.append(contentsOf: part.prefix(remaining))
                    }

                    let isCompleteLine = index < parts.count - 1
                    if isCompleteLine {
                        if lineBuffer.range(of: needle) != nil,
                           let event = parseEvent(data: lineBuffer, path: path) {
                            events.append(event)
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
        return events
    }

    private func parseEvent(data: Data, path: String) -> TokenEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "event_msg",
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let timestampText = object["timestamp"] as? String,
            let timestamp = parseDate(timestampText)
        else { return nil }

        let info = payload["info"] as? [String: Any]
        return TokenEvent(
            sessionID: sessionID(from: path),
            timestamp: timestamp,
            total: parseBreakdown(info?["total_token_usage"]),
            last: parseBreakdown(info?["last_token_usage"]),
            rateLimits: parseLocalRateLimits(payload["rate_limits"])
        )
    }

    private func aggregate(
        events: [TokenEvent],
        referenceDate: Date,
        filesScanned: Int
    ) -> LocalScanResult {
        var eventsBySession: [String: [TokenEvent]] = [:]
        for event in events {
            eventsBySession[event.sessionID, default: []].append(event)
        }

        var today = TokenBreakdown.zero
        var latestRateLimits: (date: Date, value: RateLimitSnapshot)?
        var uniqueEventCount = 0

        for (_, unsortedEvents) in eventsBySession {
            let sortedEvents = unsortedEvents.sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return (lhs.total?.totalTokens ?? -1) < (rhs.total?.totalTokens ?? -1)
                }
                return lhs.timestamp < rhs.timestamp
            }
            var previous: TokenBreakdown?
            var seen = Set<String>()

            for event in sortedEvents {
                let eventKey = [
                    String(event.timestamp.timeIntervalSince1970),
                    String(event.total?.inputTokens ?? -1),
                    String(event.total?.outputTokens ?? -1),
                    String(event.total?.totalTokens ?? -1),
                    event.rateLimits?.limitID ?? ""
                ].joined(separator: "|")
                guard seen.insert(eventKey).inserted else { continue }
                uniqueEventCount += 1

                if let rateLimits = event.rateLimits,
                   latestRateLimits == nil || event.timestamp > latestRateLimits!.date {
                    latestRateLimits = (event.timestamp, rateLimits)
                }

                guard let current = event.total else { continue }
                let delta: TokenBreakdown
                if let previous {
                    if current.totalTokens < previous.totalTokens
                        || current.inputTokens < previous.inputTokens
                        || current.outputTokens < previous.outputTokens {
                        delta = event.last ?? current
                    } else {
                        delta = current.delta(from: previous)
                    }
                } else {
                    // Forks and subagents can inherit a non-zero cumulative counter.
                    delta = event.last ?? current
                }
                previous = current

                if Calendar.current.isDate(event.timestamp, inSameDayAs: referenceDate) {
                    today = today + delta
                }
            }
        }

        return LocalScanResult(
            today: today,
            rateLimits: latestRateLimits?.value,
            matchedEvents: uniqueEventCount,
            filesScanned: filesScanned
        )
    }

    private func parseBreakdown(_ value: Any?) -> TokenBreakdown? {
        guard let raw = value as? [String: Any] else { return nil }
        guard
            let input = AppServerClient.int64Value(raw["input_tokens"]),
            let output = AppServerClient.int64Value(raw["output_tokens"])
        else { return nil }

        return TokenBreakdown(
            inputTokens: input,
            cachedInputTokens: AppServerClient.int64Value(raw["cached_input_tokens"]) ?? 0,
            outputTokens: output,
            reasoningOutputTokens: AppServerClient.int64Value(raw["reasoning_output_tokens"]) ?? 0,
            totalTokens: AppServerClient.int64Value(raw["total_tokens"]) ?? input + output
        )
    }

    private func parseLocalRateLimits(_ value: Any?) -> RateLimitSnapshot? {
        guard let raw = value as? [String: Any] else { return nil }
        return RateLimitSnapshot(
            limitID: raw["limit_id"] as? String,
            limitName: raw["limit_name"] as? String,
            primary: parseLocalWindow(raw["primary"]),
            secondary: parseLocalWindow(raw["secondary"]),
            credits: parseLocalCredits(raw["credits"]),
            planType: raw["plan_type"] as? String,
            reachedType: raw["rate_limit_reached_type"] as? String
        )
    }

    private func parseLocalWindow(_ value: Any?) -> RateLimitWindow? {
        guard let raw = value as? [String: Any] else { return nil }
        guard
            let used = AppServerClient.doubleValue(raw["used_percent"]),
            let minutes = AppServerClient.intValue(raw["window_minutes"])
        else { return nil }
        let resetSeconds = AppServerClient.doubleValue(raw["resets_at"])
        return RateLimitWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func parseLocalCredits(_ value: Any?) -> CreditInfo? {
        guard let raw = value as? [String: Any] else { return nil }
        let balance: String?
        if let string = raw["balance"] as? String {
            balance = string
        } else if let number = raw["balance"] as? NSNumber {
            balance = number.stringValue
        } else {
            balance = nil
        }
        return CreditInfo(
            hasCredits: AppServerClient.boolValue(raw["has_credits"]) ?? false,
            unlimited: AppServerClient.boolValue(raw["unlimited"]) ?? false,
            balance: balance
        )
    }

    private func parseDate(_ text: String) -> Date? {
        isoWithFractional.date(from: text) ?? isoWithoutFractional.date(from: text)
    }

    private func sessionID(from path: String) -> String {
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard filename.count >= 36 else { return filename }
        let suffix = String(filename.suffix(36))
        let parts = suffix.split(separator: "-")
        if parts.count == 5 { return suffix }
        return filename
    }
}

private enum RipgrepLocator {
    static func find(fileManager: FileManager) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/rg" })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "\(home)/.cargo/bin/rg"
        ])

        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate).inserted && fileManager.isExecutableFile(atPath: candidate)
        }
    }
}
