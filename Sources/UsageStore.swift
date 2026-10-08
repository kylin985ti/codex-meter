import Combine
import Foundation

// UsageStore prevents overlapping refreshes, so this service is only used by one
// background job at a time even though DispatchQueue requires a Sendable capture.
final class UsageService: @unchecked Sendable {
    private let appServer: AppServerClient
    private let localScanner: LocalTokenScanner
    private let fileManager: FileManager
    private var cachedOfficialRateLimits: RateLimitSnapshot?

    init(
        appServer: AppServerClient = AppServerClient(),
        localScanner: LocalTokenScanner = LocalTokenScanner(),
        fileManager: FileManager = .default
    ) {
        self.appServer = appServer
        self.localScanner = localScanner
        self.fileManager = fileManager
    }

    func fetch() -> UsageSnapshot {
        let official = appServer.fetch()
        let officialToday = official.usage?.todayTokens
        let needsLocal = officialToday == nil
        let local = needsLocal ? localScanner.scanToday() : nil
        let localLogsAvailable = hasReadableLocalLogs

        if let currentRateLimits = official.rateLimits {
            cachedOfficialRateLimits = currentRateLimits
        }
        let rateSelection = RateLimitSelection.preferOfficial(
            current: official.rateLimits,
            cached: cachedOfficialRateLimits
        )
        let rateLimits = rateSelection.snapshot
        let rateOrigin = rateSelection.origin

        let todayTokens: Int64?
        let todayBreakdown: TokenBreakdown?
        let tokenOrigin: UsageOrigin
        if let officialToday {
            todayTokens = officialToday
            todayBreakdown = nil
            tokenOrigin = .official
        } else if localLogsAvailable, let local {
            todayTokens = local.today.totalTokens
            todayBreakdown = local.today
            tokenOrigin = .localLogs
        } else {
            todayTokens = nil
            todayBreakdown = nil
            tokenOrigin = .unavailable
        }

        var notes: [String] = []
        if tokenOrigin == .localLogs {
            if official.usageEndpointSupported {
                notes.append("官方今日数据暂缺，显示本机估算")
            } else {
                notes.append("当前 Codex 版本尚无官方日用量接口，显示本机估算")
            }
        }
        if rateOrigin == .officialCache {
            notes.append("官方额度刷新失败，显示上次成功数据")
        } else if rateOrigin == .unavailable, let diagnostic = official.diagnostic {
            notes.append(diagnostic)
        }
        if let windows = rateLimits,
           [windows.primary, windows.secondary].compactMap({ $0?.resetsAt }).contains(where: { $0 < Date() }),
           rateOrigin == .officialCache {
            notes.append("官方额度快照已过重置时间，等待刷新")
        }

        return UsageSnapshot(
            rateLimits: rateLimits,
            todayTokens: todayTokens,
            todayBreakdown: todayBreakdown,
            lifetimeTokens: official.usage?.lifetimeTokens,
            rateOrigin: rateOrigin,
            tokenOrigin: tokenOrigin,
            updatedAt: Date(),
            note: notes.isEmpty ? nil : notes.joined(separator: "；")
        )
    }

    private var hasReadableLocalLogs: Bool {
        let home = fileManager.homeDirectoryForCurrentUser
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true).path
        let archived = home.appendingPathComponent(".codex/archived_sessions", isDirectory: true).path
        return fileManager.isReadableFile(atPath: sessions) || fileManager.isReadableFile(atPath: archived)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .loading
    @Published private(set) var isRefreshing = false

    var onSnapshotChange: ((UsageSnapshot) -> Void)?

    private let service: UsageService
    private var timer: Timer?

    init(service: UsageService = UsageService()) {
        self.service = service
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let service = self.service

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let next = service.fetch()
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = next
                self.isRefreshing = false
                self.onSnapshotChange?(next)
            }
        }
    }
}
