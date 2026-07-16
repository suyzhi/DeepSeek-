import Foundation

protocol DeepSeekAPIClientProtocol: Sendable {
    func fetchBalance(apiKey: String) async throws -> BalanceSnapshot
}

private struct BalanceInfoDTO: Decodable {
    let currency: String
    let totalBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
    }
}

private struct BalanceResponseDTO: Decodable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfoDTO]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

final class DeepSeekAPIClient: DeepSeekAPIClientProtocol {
    private let session: URLSession
    private let endpoint: URL
    private let now: @Sendable () -> Date

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.deepseek.com/user/balance")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.endpoint = endpoint
        self.now = now
    }

    func fetchBalance(apiKey: String) async throws -> BalanceSnapshot {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw APIError.missingAPIKey }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw APIError.transport(error.localizedDescription)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.transport("无效响应")
        }
        switch httpResponse.statusCode {
        case 200: break
        case 401, 403: throw APIError.unauthorized
        default: throw APIError.server(statusCode: httpResponse.statusCode)
        }

        let decoded: BalanceResponseDTO
        do {
            decoded = try JSONDecoder().decode(BalanceResponseDTO.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }

        guard decoded.isAvailable else { throw APIError.unavailable }
        guard !decoded.balanceInfos.isEmpty else { throw APIError.emptyBalance }

        let info = decoded.balanceInfos.first(where: { $0.currency.uppercased() == "CNY" })
            ?? decoded.balanceInfos[0]
        guard let amount = Decimal(string: info.totalBalance, locale: Locale(identifier: "en_US_POSIX")) else {
            throw APIError.invalidAmount(info.totalBalance)
        }
        return BalanceSnapshot(amount: amount, currency: info.currency.uppercased(), fetchedAt: now())
    }
}
