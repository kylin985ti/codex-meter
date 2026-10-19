import Combine
import Foundation

// UsageStore prevents overlapping refreshes, so this service is only used by one
// background job at a time even though DispatchQueue requires a Sendable capture.
final class UsageService: @unchecked Sendable {
    private let appServer: AppServerClient
    private let localScanner: LocalTokenScanner
    private let ollamaClient: OllamaClient
    private let fileManager: FileManager
    private var cachedOfficialRateLimits: RateLimitSnapshot?

    init(
        appServer: AppServerClient = AppServerClient(),
        localScanner: LocalTokenScanner = LocalTokenScanner(),
        ollamaClient: OllamaClient = OllamaClient(),
        fileManager: FileManager = .default
    ) {
        self.appServer = appServer
        self.localScanner = localScanner
        self.ollamaClient = ollamaClient
        self.fileManager = fileManager
    }

    func fetch() -> UsageSnapshot {
        // Ollama 走公网 HTTPS，与 Codex App Server 的本地握手互不相干，
        // 因此并行拉取，总耗时取决于较慢的一边而不是两者之和。
        let ollamaBox = OllamaResultBox()
        let ollamaClient = self.ollamaClient
        DispatchQueue.global(qos: .utility).async {
            ollamaBox.store(ollamaClient.fetch())
        }

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

        let ollamaResult = ollamaBox.wait()
        let ollama: OllamaSnapshot
        if let result = ollamaResult, result.session != nil || result.weekly != nil {
            ollama = OllamaSnapshot(
                session: result.session,
                weekly: result.weekly,
                purchasedUSD: result.purchasedUSD,
                requests24h: result.requests24h,
                requests7d: result.requests7d,
                origin: .ollamaOfficial,
                note: nil
            )
        } else {
            let diagnostic = ollamaResult?.diagnostic ?? "Ollama 数据未就绪"
            ollama = OllamaSnapshot(
                session: nil,
                weekly: nil,
                purchasedUSD: nil,
                requests24h: nil,
                requests7d: nil,
                origin: .unavailable,
                note: diagnostic
            )
        }

        return UsageSnapshot(
            rateLimits: rateLimits,
            todayTokens: todayTokens,
            todayBreakdown: todayBreakdown,
            lifetimeTokens: official.usage?.lifetimeTokens,
            rateOrigin: rateOrigin,
            tokenOrigin: tokenOrigin,
            ollama: ollama,
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

// 在 fetch() 内跨线程交接 Ollama 结果：主线程继续等 Codex，后台线程填充这里。
private final class OllamaResultBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: OllamaFetchResult?

    func store(_ value: OllamaFetchResult) {
        lock.lock()
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> OllamaFetchResult? {
        // OllamaClient 自身已有 12 秒请求超时，这里留出余量即可，不会长期阻塞刷新。
        _ = semaphore.wait(timeout: .now() + 20)
        lock.lock()
        defer { lock.unlock() }
        return result
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
