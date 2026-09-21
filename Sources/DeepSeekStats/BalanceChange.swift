import Foundation

/// Result of comparing the current balance with the oldest sample in the
/// selected window. Kept free of AppKit so it can be unit tested.
enum BalanceChange: Equatable, Sendable {
    /// No samples in the window, so there is nothing to show.
    case none
    /// Samples exist but the balance did not move beyond the threshold.
    case unchanged
    case spent(Decimal)
    case toppedUp(Decimal)

    /// Whether the change is large enough to collapse the popover's extra row.
    var isMeaningful: Bool {
        switch self {
        case .spent, .toppedUp: true
        case .none, .unchanged: false
        }
    }
}

enum BalanceChangeCalculator {
    static let threshold = Decimal(string: "0.01", locale: Locale(identifier: "en_US_POSIX"))!

    static func compute(snapshot: BalanceSnapshot, windowSamples: [BalanceSample]) -> BalanceChange {
        guard !windowSamples.isEmpty else { return .none }
        guard windowSamples.count >= 2, let first = windowSamples.first else { return .unchanged }

        let change = snapshot.amount - first.amount
        let magnitude = abs(change)
        guard magnitude >= threshold else { return .unchanged }
        return change < 0 ? .spent(magnitude) : .toppedUp(magnitude)
    }
}
