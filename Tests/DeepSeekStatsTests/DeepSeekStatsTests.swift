import Foundation
import Testing
@testable import DeepSeekStats

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MemoryKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }

    func read() -> String? {
        lock.withLock { value }
    }

    func save(_ key: String) {
        lock.withLock { value = key }
    }

    func delete() {
        lock.withLock { value = nil }
    }
}

private actor StubAPIClient: DeepSeekAPIClientProtocol {
    enum Result: Sendable {
        case success(BalanceSnapshot)
        case failure(APIError)
    }

    let result: Result
    private(set) var callCount = 0

    init(result: Result) { self.result = result }

    func fetchBalance(apiKey: String) async throws -> BalanceSnapshot {
        callCount += 1
        switch result {
        case .success(let snapshot): return snapshot
        case .failure(let error): throw error
        }
    }
}

@Suite(.serialized)
struct DeepSeekAPIClientTests {
    @Test func testDecodesCNYFromMultipleCurrencies() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = makeClient(
            status: 200,
            json: """
            {"is_available":true,"balance_infos":[
              {"currency":"USD","total_balance":"10.00"},
              {"currency":"CNY","total_balance":"42.25"}
            ]}
            """,
            now: now
        )

        let snapshot = try await client.fetchBalance(apiKey: "test-key")
        #expect(snapshot == BalanceSnapshot(amount: Decimal(string: "42.25")!, currency: "CNY", fetchedAt: now))
    }

    @Test func testMapsUnauthorizedWithoutLeakingResponseBody() async {
        let client = makeClient(status: 401, json: "{\"secret\":\"do-not-log\"}")
        await expectAPIError(.unauthorized) {
            _ = try await client.fetchBalance(apiKey: "bad-key")
        }
    }

    @Test func testRejectsUnavailableEmptyAndInvalidAmounts() async {
        await expectAPIError(.unavailable) {
            _ = try await makeClient(status: 200, json: "{\"is_available\":false,\"balance_infos\":[]}")
                .fetchBalance(apiKey: "key")
        }
        await expectAPIError(.emptyBalance) {
            _ = try await makeClient(status: 200, json: "{\"is_available\":true,\"balance_infos\":[]}")
                .fetchBalance(apiKey: "key")
        }
        await expectAPIError(.invalidAmount("oops")) {
            _ = try await makeClient(
                status: 200,
                json: "{\"is_available\":true,\"balance_infos\":[{\"currency\":\"CNY\",\"total_balance\":\"oops\"}]}"
            ).fetchBalance(apiKey: "key")
        }
    }

    @Test func testRejectsMalformedJSONAndServerErrors() async {
        await expectAPIError(.server(statusCode: 503)) {
            _ = try await makeClient(status: 503, json: "service unavailable")
                .fetchBalance(apiKey: "key")
        }
        do {
            _ = try await makeClient(status: 200, json: "not-json")
                .fetchBalance(apiKey: "key")
            Issue.record("Expected decoding error")
        } catch let error as APIError {
            guard case .decoding = error else {
                Issue.record("Expected decoding error, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func testMapsRateLimitAndTransportFailures() async {
        await expectAPIError(.rateLimited) {
            _ = try await makeClient(status: 429, json: "{\"error\":\"rate limit\"}")
                .fetchBalance(apiKey: "key")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let url = URL(string: "https://example.invalid/balance")!
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let client = DeepSeekAPIClient(session: URLSession(configuration: configuration), endpoint: url)
        do {
            _ = try await client.fetchBalance(apiKey: "key")
            Issue.record("Expected transport error")
        } catch let error as APIError {
            guard case .transport = error else {
                Issue.record("Expected transport error, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeClient(status: Int, json: String, now: Date = Date()) -> DeepSeekAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let url = URL(string: "https://example.invalid/balance")!
        MockURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        return DeepSeekAPIClient(
            session: URLSession(configuration: configuration),
            endpoint: url,
            now: { now }
        )
    }

    private func expectAPIError(
        _ expected: APIError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as APIError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite(.serialized)
struct BalanceHistoryStoreTests {
    @Test func testMigratesLegacyDataAndRemovesDefaultsKey() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = fixture.defaults
        let legacy = [Legacy(date: "2026-07-15 10:30", balance: 12.5, currency: "cny")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: BalanceHistoryStore.legacyDefaultsKey)
        let now = fixture.date("2026-07-16 10:30")
        let store = BalanceHistoryStore(fileURL: fixture.fileURL, defaultsSuiteName: fixture.suiteName, now: { now })

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].currency == "CNY")
        #expect(loaded[0].amount == Decimal(string: "12.5"))
        #expect(defaults.data(forKey: BalanceHistoryStore.legacyDefaultsKey) == nil)
    }

    @Test func testReplacesSameMinuteAndKeepsCurrenciesSeparate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = fixture.date("2026-07-16 10:30")
        let store = BalanceHistoryStore(fileURL: fixture.fileURL, defaultsSuiteName: fixture.suiteName, now: { now })
        try await store.add(BalanceSample(timestamp: now, amount: 10, currency: "CNY"))
        try await store.add(BalanceSample(timestamp: now.addingTimeInterval(20), amount: 9, currency: "CNY"))
        try await store.add(BalanceSample(timestamp: now.addingTimeInterval(20), amount: 3, currency: "USD"))

        let loaded = try await store.load()
        #expect(loaded.count == 2)
        #expect(loaded.first(where: { $0.currency == "CNY" })?.amount == 9)
        #expect(loaded.first(where: { $0.currency == "USD" })?.amount == 3)
    }

    @Test func testRemovesSamplesOlderThanThirtyDays() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = fixture.date("2026-07-16 10:30")
        let store = BalanceHistoryStore(fileURL: fixture.fileURL, defaultsSuiteName: fixture.suiteName, now: { now })
        try await store.add(BalanceSample(timestamp: now.addingTimeInterval(-31 * 86_400), amount: 10, currency: "CNY"))
        try await store.add(BalanceSample(timestamp: now.addingTimeInterval(-29 * 86_400), amount: 9, currency: "CNY"))

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].amount == 9)
    }

    @Test func testQuarantinesCorruptHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fixture.fileURL)
        let store = BalanceHistoryStore(fileURL: fixture.fileURL, defaultsSuiteName: fixture.suiteName)

        #expect(try await store.load().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(files.contains { $0.lastPathComponent.hasPrefix("history.corrupt-") })
    }

    private struct Legacy: Codable {
        let date: String
        let balance: Double
        let currency: String
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let fileURL: URL
        let defaults: UserDefaults
        let suiteName: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeepSeekStatsTests-\(UUID().uuidString)")
            fileURL = directory.appendingPathComponent("history.json")
            suiteName = "DeepSeekStatsTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
        }

        func date(_ value: String) -> Date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.date(from: value)!
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

struct ChartSeriesBuilderTests {
    @Test func testUsesActualTimestampsForXPositions() {
        let end = Date(timeIntervalSince1970: 10_000)
        let start = end.addingTimeInterval(-300)
        let samples = [
            BalanceSample(timestamp: start, amount: 10, currency: "CNY"),
            BalanceSample(timestamp: start.addingTimeInterval(30), amount: 9, currency: "CNY"),
            BalanceSample(timestamp: end, amount: 8, currency: "CNY"),
        ]
        let series = ChartSeriesBuilder.build(
            samples: samples,
            currency: "CNY",
            interval: ChartInterval(label: "5分", minutes: 5),
            endingAt: end
        )

        #expect(abs(series.xFraction(for: series.points[1].timestamp) - 0.1) < 0.0001)
        #expect(series.xFraction(for: series.points[2].timestamp) == 1)
    }

    @Test func testObservedSeriesFillsPlotWithoutLosingTimeSpacing() {
        let end = Date(timeIntervalSince1970: 10_000)
        let samples = [
            BalanceSample(timestamp: end.addingTimeInterval(-240), amount: 10, currency: "CNY"),
            BalanceSample(timestamp: end.addingTimeInterval(-180), amount: 9, currency: "CNY"),
            BalanceSample(timestamp: end, amount: 8, currency: "CNY"),
        ]
        let series = ChartSeriesBuilder.build(
            samples: samples,
            currency: "CNY",
            interval: ChartInterval(label: "5分", minutes: 5),
            endingAt: end
        )

        #expect(series.xFraction(for: series.points[0].timestamp) == 0)
        #expect(abs(series.xFraction(for: series.points[1].timestamp) - 0.25) < 0.0001)
        #expect(series.xFraction(for: series.points[2].timestamp) == 1)
    }

    @Test func testAggregationPreservesInteriorExtremes() {
        let end = Date(timeIntervalSince1970: 20_000)
        let base = end.addingTimeInterval(-3_000)
        let samples = [10, 4, 16, 9].enumerated().map { index, value in
            BalanceSample(
                timestamp: base.addingTimeInterval(TimeInterval(index * 120)),
                amount: Decimal(value),
                currency: "CNY"
            )
        }
        let series = ChartSeriesBuilder.build(
            samples: samples,
            currency: "CNY",
            interval: ChartInterval(label: "6时", minutes: 360),
            endingAt: end
        )

        #expect(series.points.contains { $0.amount == 4 })
        #expect(series.points.contains { $0.amount == 16 })
    }

    @Test func testFlatSeriesGetsSymmetricVerticalPadding() {
        let end = Date(timeIntervalSince1970: 1_000)
        let series = ChartSeriesBuilder.build(
            samples: [
                BalanceSample(timestamp: end.addingTimeInterval(-60), amount: 10, currency: "CNY"),
                BalanceSample(timestamp: end, amount: 10, currency: "CNY"),
            ],
            currency: "CNY",
            interval: ChartInterval(label: "5分", minutes: 5),
            endingAt: end
        )
        #expect(abs((10 - series.minimum) - (series.maximum - 10)) < 0.0001)
    }

    @Test func testWindowedSamplesFilterCurrencyAndWindow() {
        let end = Date(timeIntervalSince1970: 10_000)
        let samples = [
            BalanceSample(timestamp: end.addingTimeInterval(-60), amount: 1, currency: "CNY"),
            BalanceSample(timestamp: end.addingTimeInterval(-60), amount: 2, currency: "USD"),
            BalanceSample(timestamp: end.addingTimeInterval(-1_000), amount: 3, currency: "CNY"),
            BalanceSample(timestamp: end.addingTimeInterval(60), amount: 4, currency: "CNY"),
        ]
        let windowed = ChartSeriesBuilder.windowedSamples(
            samples: samples,
            currency: "CNY",
            interval: ChartInterval(label: "5分", minutes: 5),
            endingAt: end
        )
        #expect(windowed.count == 1)
        #expect(windowed[0].amount == 1)
    }
}

@Suite(.serialized)
struct APIKeyProviderTests {
    @Test func testPrefersKeychainOverEnvironmentAndLegacyFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent(".env")
        try Data("DEEPSEEK_API_KEY=legacy".utf8).write(to: legacy)
        let provider = APIKeyProvider(
            keyStore: MemoryKeyStore("keychain"),
            environment: { ["DEEPSEEK_API_KEY": "environment"] },
            legacyFileURL: legacy
        )
        #expect(try await provider.apiKey() == "keychain")
    }

    @Test func testImportsLegacyKeyIntoStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent(".env")
        try Data("export DEEPSEEK_API_KEY='legacy-key'".utf8).write(to: legacy)
        let store = MemoryKeyStore()
        let provider = APIKeyProvider(keyStore: store, environment: { [:] }, legacyFileURL: legacy)

        #expect(try await provider.apiKey() == "legacy-key")
        #expect(store.read() == "legacy-key")
    }

    @Test func testSourceReportsEachConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent(".env")
        try Data("DEEPSEEK_API_KEY=legacy".utf8).write(to: legacy)

        let keychain = APIKeyProvider(
            keyStore: MemoryKeyStore("stored"),
            environment: { ["DEEPSEEK_API_KEY": "env"] },
            legacyFileURL: legacy
        )
        #expect(await keychain.source() == .keychain)

        let environment = APIKeyProvider(
            keyStore: MemoryKeyStore(nil),
            environment: { ["DEEPSEEK_API_KEY": "env"] },
            legacyFileURL: legacy
        )
        #expect(await environment.source() == .environment)

        let file = APIKeyProvider(keyStore: MemoryKeyStore(nil), environment: { [:] }, legacyFileURL: legacy)
        #expect(await file.source() == .legacyFile)

        let missing = APIKeyProvider(
            keyStore: MemoryKeyStore(nil),
            environment: { [:] },
            legacyFileURL: directory.appendingPathComponent("missing.env")
        )
        #expect(await missing.source() == .missing)
    }
}

@MainActor
struct RefreshCoordinatorTests {
    @Test func testUsesCachedSnapshotWhenRefreshFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cachedDate = Date(timeIntervalSince1970: 5_000)
        let store = BalanceHistoryStore(
            fileURL: directory.appendingPathComponent("history.json"),
            now: { cachedDate.addingTimeInterval(60) }
        )
        try await store.add(BalanceSample(timestamp: cachedDate, amount: 20, currency: "CNY"))
        let api = StubAPIClient(result: .failure(.transport("offline")))
        let provider = APIKeyProvider(keyStore: MemoryKeyStore("key"), environment: { [:] })
        let coordinator = RefreshCoordinator(apiClient: api, historyStore: store, keyProvider: provider)

        coordinator.refresh(reason: .manual)
        await waitUntilFinished(coordinator)

        guard case .stale(let snapshot, _, let error) = coordinator.state else {
            Issue.record("Expected stale state")
            return
        }
        #expect(snapshot.amount == 20)
        #expect(error == .transport("offline"))
    }

    @Test func testCoalescesConcurrentRefreshRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BalanceHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let api = StubAPIClient(result: .success(BalanceSnapshot(amount: 10, currency: "CNY", fetchedAt: Date())))
        let provider = APIKeyProvider(keyStore: MemoryKeyStore("key"), environment: { [:] })
        let coordinator = RefreshCoordinator(apiClient: api, historyStore: store, keyProvider: provider)

        coordinator.refresh(reason: .manual)
        coordinator.refresh(reason: .popover)
        coordinator.refresh(reason: .timer)
        await waitUntilFinished(coordinator)

        let callCount = await api.callCount
        #expect(callCount == 1)
    }

    @Test func testSuccessPathProducesFreshState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetched = Date(timeIntervalSince1970: 5_000)
        let store = BalanceHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { fetched })
        let api = StubAPIClient(result: .success(BalanceSnapshot(amount: 10, currency: "CNY", fetchedAt: fetched)))
        let provider = APIKeyProvider(keyStore: MemoryKeyStore("key"), environment: { [:] })
        let coordinator = RefreshCoordinator(apiClient: api, historyStore: store, keyProvider: provider)

        coordinator.refresh(reason: .manual)
        await waitUntilFinished(coordinator)

        guard case .fresh(let snapshot, let history) = coordinator.state else {
            Issue.record("Expected fresh state")
            return
        }
        #expect(snapshot.amount == 10)
        #expect(history.count == 1)
    }

    @Test func testTimerRefreshKeepsCachedSnapshotVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetched = Date(timeIntervalSince1970: 5_000)
        let store = BalanceHistoryStore(fileURL: directory.appendingPathComponent("history.json"), now: { fetched })
        let api = StubAPIClient(result: .success(BalanceSnapshot(amount: 10, currency: "CNY", fetchedAt: fetched)))
        let provider = APIKeyProvider(keyStore: MemoryKeyStore("key"), environment: { [:] })
        let coordinator = RefreshCoordinator(apiClient: api, historyStore: store, keyProvider: provider)

        coordinator.refresh(reason: .manual)
        await waitUntilFinished(coordinator)

        coordinator.refresh(reason: .timer)
        if case .loading = coordinator.state {
            Issue.record("Timer refresh should not show a loading state when a snapshot is cached")
        }
        await waitUntilFinished(coordinator)
    }

    @Test func testMissingAPIKeyWithoutCacheFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BalanceHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let api = StubAPIClient(result: .success(BalanceSnapshot(amount: 1, currency: "CNY", fetchedAt: Date())))
        let provider = APIKeyProvider(
            keyStore: MemoryKeyStore(nil),
            environment: { [:] },
            legacyFileURL: directory.appendingPathComponent("missing.env")
        )
        let coordinator = RefreshCoordinator(apiClient: api, historyStore: store, keyProvider: provider)

        coordinator.refresh(reason: .manual)
        await waitUntilFinished(coordinator)

        guard case .failed(let error) = coordinator.state else {
            Issue.record("Expected failed state")
            return
        }
        #expect(error == .missingAPIKey)
    }

    private func waitUntilFinished(_ coordinator: RefreshCoordinator) async {
        for _ in 0..<100 {
            if case .loading = coordinator.state {
                try? await Task.sleep(for: .milliseconds(10))
            } else {
                return
            }
        }
        Issue.record("Refresh did not finish")
    }
}

@MainActor
struct BalanceChangeCalculatorTests {
    private func snapshot(_ amount: String, currency: String = "CNY") -> BalanceSnapshot {
        BalanceSnapshot(
            amount: Decimal(string: amount)!,
            currency: currency,
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test func testNoSamplesIsNone() {
        let change = BalanceChangeCalculator.compute(snapshot: snapshot("10"), windowSamples: [])
        #expect(change == .none)
        #expect(!change.isMeaningful)
    }

    @Test func testSingleSampleIsUnchanged() {
        let sample = BalanceSample(timestamp: Date(timeIntervalSince1970: 1_000), amount: 10, currency: "CNY")
        let change = BalanceChangeCalculator.compute(snapshot: snapshot("10"), windowSamples: [sample])
        #expect(change == .unchanged)
        #expect(!change.isMeaningful)
    }

    @Test func testDetectsSpendingAndTopUp() {
        let start = BalanceSample(timestamp: Date(timeIntervalSince1970: 1_000), amount: 10, currency: "CNY")
        let end = BalanceSample(timestamp: Date(timeIntervalSince1970: 1_060), amount: 12, currency: "CNY")
        #expect(BalanceChangeCalculator.compute(snapshot: snapshot("5"), windowSamples: [start, end])
            == .spent(Decimal(string: "5")!))
        #expect(BalanceChangeCalculator.compute(snapshot: snapshot("15"), windowSamples: [start, end])
            == .toppedUp(Decimal(string: "5")!))
    }

    @Test func testSubCentChangeIsIgnored() {
        let start = BalanceSample(timestamp: Date(timeIntervalSince1970: 1_000), amount: 10, currency: "CNY")
        let end = BalanceSample(timestamp: Date(timeIntervalSince1970: 1_060), amount: 10, currency: "CNY")
        #expect(BalanceChangeCalculator.compute(snapshot: snapshot("10.009"), windowSamples: [start, end]) == .unchanged)
    }
}

@MainActor
struct MoneyFormatterTests {
    @Test func testFormatsAmountWithRequestedPrecision() {
        let value = MoneyFormatter.string(amount: Decimal(string: "42.256")!, currency: "cny")
        #expect(value.contains("42.26"))
    }
}
