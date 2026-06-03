import AppKit
import Foundation

// MARK: - Data Models
struct BalanceInfo: Codable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

struct BalanceResponse: Codable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

// MARK: - Balance History (local tracking)
struct BalancePoint: Codable {
    let date: String  // yyyy-MM-dd HH:mm
    let balance: Double
    let currency: String
}

@MainActor
class BalanceHistoryManager {
    static let shared = BalanceHistoryManager()
    private let defaultsKey = "balance_history"

    func load() -> [BalancePoint] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let history = try? JSONDecoder().decode([BalancePoint].self, from: data) else {
            return []
        }
        return history
    }

    func addPoint(balance: Double, currency: String) {
        var history = load()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let point = BalancePoint(date: fmt.string(from: Date()), balance: balance, currency: currency)
        history.append(point)

        // Keep only last 7 days
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        history = history.filter {
            guard let d = fmt.date(from: $0.date) else { return false }
            return d >= sevenDaysAgo
        }

        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Get daily aggregated snapshots for charting (latest per day)
    func dailySnapshots() -> [(date: String, balance: Double)] {
        let all = load()
        var byDay: [String: BalancePoint] = [:]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"

        for point in all {
            let day = String(point.date.prefix(10)) // yyyy-MM-dd
            if let existing = byDay[day] {
                // Keep later snapshot for the day
                if point.date > existing.date {
                    byDay[day] = point
                }
            } else {
                byDay[day] = point
            }
        }
        return byDay.sorted { $0.key < $1.key }.map { ($0.key, $0.value.balance) }
    }
}

// MARK: - API Client
class DeepSeekAPIClient: @unchecked Sendable {
    static let shared = DeepSeekAPIClient()
    private let session: URLSession = .shared

    enum APIError: Error, LocalizedError {
        case noApiKey
        case networkError(String)
        case decodingError(String)

        var errorDescription: String? {
            switch self {
            case .noApiKey: return "未找到 API Key"
            case .networkError(let msg): return "网络错误: \(msg)"
            case .decodingError(let msg): return "数据解析错误: \(msg)"
            }
        }
    }

    private func loadAPIKey() throws -> String {
        let envPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/.env").path
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            if let envKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] {
                return envKey
            }
            throw APIError.noApiKey
        }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("DEEPSEEK_API_KEY=") {
                let key = String(trimmed.dropFirst("DEEPSEEK_API_KEY=".count))
                return key.trimmingCharacters(in: .init(charactersIn: "\"'"))
            }
        }
        throw APIError.noApiKey
    }

    func fetchBalance() async throws -> BalanceResponse {
        let key = try loadAPIKey()
        // Official DeepSeek balance endpoint (no /v1/ prefix)
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw APIError.networkError("无效响应")
        }
        guard httpResp.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw APIError.networkError("HTTP \(httpResp.statusCode): \(body.prefix(100))")
        }
        return try JSONDecoder().decode(BalanceResponse.self, from: data)
    }
}
