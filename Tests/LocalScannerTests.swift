import Foundation

@main
struct LocalScannerTests {
    static func main() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("CodexMeterTests-\(UUID().uuidString)", isDirectory: true)
        let active = base.appendingPathComponent("sessions", isDirectory: true)
        let archived = base.appendingPathComponent("archived", isDirectory: true)
        try fileManager.createDirectory(at: active, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let calendar = Calendar.current
        let reference = Date()
        let start = calendar.startOfDay(for: reference)
        let yesterday = calendar.date(byAdding: .minute, value: -10, to: start)!
        let hour8 = calendar.date(byAdding: .hour, value: 8, to: start)!
        let hour9 = calendar.date(byAdding: .hour, value: 9, to: start)!
        let hour10 = calendar.date(byAdding: .hour, value: 10, to: start)!

        let sessionA = "11111111-1111-1111-1111-111111111111"
        let sessionAEvents = [
            event(
                at: hour8,
                total: breakdown(input: 900, cached: 500, output: 100),
                last: breakdown(input: 90, cached: 50, output: 10),
                usedPercent: 20
            ),
            event(
                at: calendar.date(byAdding: .minute, value: 1, to: hour8)!,
                total: breakdown(input: 900, cached: 500, output: 100),
                last: breakdown(input: 90, cached: 50, output: 10),
                usedPercent: 20
            ),
            event(
                at: calendar.date(byAdding: .minute, value: 2, to: hour8)!,
                total: breakdown(input: 1_125, cached: 600, output: 125),
                last: breakdown(input: 225, cached: 100, output: 25),
                usedPercent: 25
            )
        ]
        try write(sessionAEvents, to: active.appendingPathComponent("rollout-test-\(sessionA).jsonl"))
        // Same rollout in the archive must not be counted a second time.
        try write(sessionAEvents, to: archived.appendingPathComponent("rollout-copy-\(sessionA).jsonl"))

        let sessionB = "22222222-2222-2222-2222-222222222222"
        try write([
            event(
                at: yesterday,
                total: breakdown(input: 450, cached: 100, output: 50),
                last: breakdown(input: 450, cached: 100, output: 50)
            ),
            event(
                at: hour9,
                total: breakdown(input: 630, cached: 180, output: 70),
                last: breakdown(input: 180, cached: 80, output: 20)
            )
        ], to: active.appendingPathComponent("rollout-test-\(sessionB).jsonl"))

        let sessionC = "33333333-3333-3333-3333-333333333333"
        try write([
            event(
                at: hour10,
                total: breakdown(input: 90, cached: 10, output: 10),
                last: breakdown(input: 90, cached: 10, output: 10)
            ),
            // Simulate a cumulative counter reset.
            event(
                at: calendar.date(byAdding: .minute, value: 5, to: hour10)!,
                total: breakdown(input: 45, cached: 5, output: 5),
                last: breakdown(input: 45, cached: 5, output: 5)
            )
        ], to: active.appendingPathComponent("rollout-test-\(sessionC).jsonl"))

        let result = LocalTokenScanner(roots: [active, archived]).scanToday(referenceDate: reference)
        try require(result.today.totalTokens == 700, "expected 700 tokens, got \(result.today.totalTokens)")
        try require(result.today.inputTokens == 630, "expected 630 input tokens")
        try require(result.today.outputTokens == 70, "expected 70 output tokens")
        try require(result.rateLimits?.primary?.remainingPercent == 75, "expected 75% remaining")
        try require(result.filesScanned == 4, "expected four fixture files")

        let currentSelection = RateLimitSelection.preferOfficial(current: result.rateLimits, cached: nil)
        try require(currentSelection.origin == .official, "current official quota must win")
        let cachedSelection = RateLimitSelection.preferOfficial(current: nil, cached: result.rateLimits)
        try require(cachedSelection.origin == .officialCache, "official cache must replace log fallback")
        try require(cachedSelection.snapshot?.primary?.remainingPercent == 75, "cached official quota should be retained")
        let unavailableSelection = RateLimitSelection.preferOfficial(current: nil, cached: nil)
        try require(unavailableSelection.origin == .unavailable, "missing official quota must stay unavailable")

        print("LocalScannerTests passed: total=\(result.today.totalTokens), remaining=\(Int(result.rateLimits!.primary!.remainingPercent))%")
    }

    private static func breakdown(input: Int64, cached: Int64, output: Int64) -> [String: Any] {
        [
            "input_tokens": input,
            "cached_input_tokens": cached,
            "output_tokens": output,
            "reasoning_output_tokens": output / 2,
            "total_tokens": input + output
        ]
    }

    private static func event(
        at date: Date,
        total: [String: Any],
        last: [String: Any],
        usedPercent: Double? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "token_count",
            "info": [
                "total_token_usage": total,
                "last_token_usage": last,
                "model_context_window": 200_000
            ]
        ]
        if let usedPercent {
            payload["rate_limits"] = [
                "limit_id": "codex",
                "limit_name": NSNull(),
                "primary": [
                    "used_percent": usedPercent,
                    "window_minutes": 300,
                    "resets_at": date.addingTimeInterval(3_600).timeIntervalSince1970
                ],
                "secondary": [
                    "used_percent": 5,
                    "window_minutes": 10_080,
                    "resets_at": date.addingTimeInterval(86_400).timeIntervalSince1970
                ],
                "credits": NSNull(),
                "plan_type": "test",
                "rate_limit_reached_type": NSNull()
            ]
        }
        return [
            "timestamp": isoString(date),
            "type": "event_msg",
            "payload": payload
        ]
    }

    private static func write(_ events: [[String: Any]], to url: URL) throws {
        let lines = try events.map { event -> String in
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "CodexMeterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
