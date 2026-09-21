import Foundation

protocol BalanceHistoryStoreProtocol: Sendable {
    func load() async throws -> [BalanceSample]
    @discardableResult func add(_ sample: BalanceSample) async throws -> [BalanceSample]
    func clear() async throws
}

private struct LegacyBalancePoint: Decodable {
    let date: String
    let balance: Double
    let currency: String
}

actor BalanceHistoryStore: BalanceHistoryStoreProtocol {
    static let legacyDefaultsKey = "balance_history"

    private let fileURL: URL
    private let defaultsSuiteName: String?
    private let now: @Sendable () -> Date
    private let retention: TimeInterval
    private var cachedSamples: [BalanceSample]?

    init(
        fileURL: URL? = nil,
        defaultsSuiteName: String? = nil,
        retentionDays: Int = 30,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DeepSeekStats", isDirectory: true)
            self.fileURL = base.appendingPathComponent("history.json")
        }
        self.defaultsSuiteName = defaultsSuiteName
        self.retention = TimeInterval(retentionDays * 86_400)
        self.now = now
    }

    func load() async throws -> [BalanceSample] {
        try migrateLegacyIfNeeded()

        // Keep the decoded history in memory so a refresh does not pay for
        // decoding the whole 30-day file twice (add + reload).
        if let cached = cachedSamples {
            let normalized = normalize(cached)
            cachedSamples = normalized
            return normalized
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedSamples = []
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            var samples = try decoder.decode([BalanceSample].self, from: data)
            let normalized = normalize(samples)
            if normalized != samples {
                samples = normalized
                try save(samples)
            }
            cachedSamples = samples
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            return samples
        } catch {
            try quarantineCorruptFile()
            cachedSamples = []
            return []
        }
    }

    @discardableResult
    func add(_ sample: BalanceSample) async throws -> [BalanceSample] {
        var samples = try await load()
        let key = minuteKey(for: sample)
        samples.removeAll { minuteKey(for: $0) == key }
        samples.append(BalanceSample(
            timestamp: sample.timestamp,
            amount: sample.amount,
            currency: sample.currency.uppercased()
        ))
        let normalized = normalize(samples)
        try save(normalized)
        cachedSamples = normalized
        return normalized
    }

    func clear() async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        cachedSamples = []
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    private func normalize(_ samples: [BalanceSample]) -> [BalanceSample] {
        let cutoff = now().addingTimeInterval(-retention)
        var byMinute: [String: BalanceSample] = [:]
        for sample in samples where sample.timestamp >= cutoff {
            byMinute[minuteKey(for: sample)] = BalanceSample(
                timestamp: sample.timestamp,
                amount: sample.amount,
                currency: sample.currency.uppercased()
            )
        }
        return byMinute.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func minuteKey(for sample: BalanceSample) -> String {
        let minute = Int(sample.timestamp.timeIntervalSince1970 / 60)
        return "\(sample.currency.uppercased())|\(minute)"
    }

    private func migrateLegacyIfNeeded() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { return }
        guard let data = defaults.data(forKey: Self.legacyDefaultsKey) else { return }

        let legacy: [LegacyBalancePoint]
        do {
            legacy = try JSONDecoder().decode([LegacyBalancePoint].self, from: data)
        } catch {
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let migrated = legacy.compactMap { point -> BalanceSample? in
            guard let timestamp = formatter.date(from: point.date),
                  let amount = Decimal(string: String(point.balance), locale: Locale(identifier: "en_US_POSIX")) else {
                return nil
            }
            return BalanceSample(timestamp: timestamp, amount: amount, currency: point.currency.uppercased())
        }
        try save(normalize(migrated))
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    private func save(_ samples: [BalanceSample]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(samples)
        try data.write(to: fileURL, options: .atomic)
    }

    private func quarantineCorruptFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let stamp = Int(now().timeIntervalSince1970)
        let corruptURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("history.corrupt-\(stamp).json")
        if FileManager.default.fileExists(atPath: corruptURL.path) {
            try FileManager.default.removeItem(at: corruptURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: corruptURL)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Machine-read file: pretty printing only bloats it and slows writes.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var defaults: UserDefaults {
        if let defaultsSuiteName {
            return UserDefaults(suiteName: defaultsSuiteName)!
        }
        return .standard
    }
}
