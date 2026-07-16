import Foundation

@MainActor
final class RefreshCoordinator {
    private let apiClient: any DeepSeekAPIClientProtocol
    private let historyStore: any BalanceHistoryStoreProtocol
    private let keyProvider: APIKeyProvider
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var state: BalanceViewState = .loading(previous: nil)

    var onStateChange: ((BalanceViewState) -> Void)?

    init(
        apiClient: any DeepSeekAPIClientProtocol,
        historyStore: any BalanceHistoryStoreProtocol,
        keyProvider: APIKeyProvider
    ) {
        self.apiClient = apiClient
        self.historyStore = historyStore
        self.keyProvider = keyProvider
    }

    func refresh(reason: RefreshReason) {
        guard task == nil else { return }
        generation += 1
        let currentGeneration = generation
        setState(.loading(previous: state.snapshot))
        task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
            if self.generation == currentGeneration {
                self.task = nil
            }
        }
    }

    func cancelAndRefresh(reason: RefreshReason) {
        generation += 1
        task?.cancel()
        task = nil
        refresh(reason: reason)
    }

    private func performRefresh() async {
        do {
            let apiKey = try await keyProvider.apiKey()
            let snapshot = try await apiClient.fetchBalance(apiKey: apiKey)
            try Task.checkCancellation()
            let sample = BalanceSample(
                timestamp: snapshot.fetchedAt,
                amount: snapshot.amount,
                currency: snapshot.currency
            )
            try await historyStore.add(sample)
            let history = try await historyStore.load()
            try Task.checkCancellation()
            setState(.fresh(snapshot: snapshot, history: history))
        } catch is CancellationError {
            return
        } catch {
            let apiError = normalize(error)
            let history = (try? await historyStore.load()) ?? []
            if let latest = history.max(by: { $0.timestamp < $1.timestamp }) {
                let cached = BalanceSnapshot(
                    amount: latest.amount,
                    currency: latest.currency,
                    fetchedAt: latest.timestamp
                )
                setState(.stale(snapshot: cached, history: history, error: apiError))
            } else {
                setState(.failed(apiError))
            }
        }
    }

    private func normalize(_ error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        return .transport(error.localizedDescription)
    }

    private func setState(_ newState: BalanceViewState) {
        state = newState
        onStateChange?(newState)
    }
}
