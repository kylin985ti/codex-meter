import Foundation

@main
struct LiveProbe {
    static func main() {
        let appServer = AppServerClient().fetch()
        let local = LocalTokenScanner().scanToday()
        let output: [String: Any] = [
            "codexExecutableFound": appServer.executablePath != nil,
            "officialRateAvailable": appServer.rateLimits != nil,
            "officialUsageAvailable": appServer.usage?.todayTokens != nil,
            "primaryUsedPercent": (appServer.rateLimits?.primary?.usedPercent).map { $0 as Any } ?? NSNull(),
            "primaryRemainingPercent": (appServer.rateLimits?.primary?.remainingPercent).map { $0 as Any } ?? NSNull(),
            "primaryWindowMinutes": (appServer.rateLimits?.primary?.windowMinutes).map { $0 as Any } ?? NSNull(),
            "secondaryRemainingPercent": (appServer.rateLimits?.secondary?.remainingPercent).map { $0 as Any } ?? NSNull(),
            "localPrimaryRemainingPercent": (local.rateLimits?.primary?.remainingPercent).map { $0 as Any } ?? NSNull(),
            "localTodayTokens": local.today.totalTokens,
            "localFilesScanned": local.filesScanned,
            "localEventsMatched": local.matchedEvents
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
