import Foundation

struct BalanceSnapshot: Sendable, Equatable {
    let amount: Decimal
    let currency: String
    let fetchedAt: Date
}

struct BalanceSample: Codable, Sendable, Equatable {
    let timestamp: Date
    let amount: Decimal
    let currency: String
}

enum BalanceViewState: Sendable, Equatable {
    case loading(previous: BalanceSnapshot?)
    case fresh(snapshot: BalanceSnapshot, history: [BalanceSample])
    case stale(snapshot: BalanceSnapshot, history: [BalanceSample], error: APIError)
    case failed(APIError)

    var snapshot: BalanceSnapshot? {
        switch self {
        case .loading(let previous): previous
        case .fresh(let snapshot, _), .stale(let snapshot, _, _): snapshot
        case .failed: nil
        }
    }
}

enum RefreshReason: Sendable {
    case launch
    case timer
    case popover
    case manual
    case settingsChanged
}

enum APIError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case unauthorized
    case unavailable
    case emptyBalance
    case invalidAmount(String)
    case transport(String)
    case server(statusCode: Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "未配置 API Key"
        case .unauthorized: "API Key 无效或无权访问余额"
        case .unavailable: "DeepSeek 暂未提供余额信息"
        case .emptyBalance: "接口未返回余额数据"
        case .invalidAmount: "余额格式无效"
        case .transport(let message): "网络错误：\(message)"
        case .server(let statusCode): "DeepSeek 服务错误（HTTP \(statusCode)）"
        case .decoding: "无法解析 DeepSeek 返回的数据"
        }
    }
}

enum MoneyFormatter {
    static func string(amount: Decimal, currency: String, fractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: amount as NSDecimalNumber)
            ?? "\(currency.uppercased()) \(amount)"
    }
}
