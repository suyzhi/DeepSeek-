import Foundation

struct ChartInterval: Sendable, Equatable {
    let label: String
    let minutes: Int

    static let supported: [ChartInterval] = [
        ChartInterval(label: "5分", minutes: 5),
        ChartInterval(label: "1时", minutes: 60),
        ChartInterval(label: "6时", minutes: 360),
        ChartInterval(label: "12时", minutes: 720),
        ChartInterval(label: "1天", minutes: 1_440),
        ChartInterval(label: "7天", minutes: 10_080),
    ]
}

struct ChartPoint: Sendable, Equatable {
    let timestamp: Date
    let amount: Decimal
}

struct ChartSeries: Sendable, Equatable {
    let start: Date
    let end: Date
    let points: [ChartPoint]
    let minimum: Double
    let maximum: Double

    func xFraction(for date: Date) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }
}

enum ChartSeriesBuilder {
    static func build(
        samples: [BalanceSample],
        currency: String,
        interval: ChartInterval,
        endingAt end: Date
    ) -> ChartSeries {
        let start = end.addingTimeInterval(-TimeInterval(interval.minutes * 60))
        let filtered = windowedSamples(
            samples: samples,
            currency: currency,
            interval: interval,
            endingAt: end
        )

        let points = aggregate(filtered, bucketSize: bucketSize(for: interval))
            .map { ChartPoint(timestamp: $0.timestamp, amount: $0.amount) }
        let values = points.map { ($0.amount as NSDecimalNumber).doubleValue }
        let domain = yDomain(values)
        let displayStart = points.first?.timestamp ?? start
        let displayEnd = points.last?.timestamp ?? end
        return ChartSeries(
            start: displayStart,
            end: displayEnd,
            points: points,
            minimum: domain.min,
            maximum: domain.max
        )
    }

    /// Currency-filtered, time-windowed samples sorted by timestamp.
    /// Shared by the chart and the balance-change calculation.
    static func windowedSamples(
        samples: [BalanceSample],
        currency: String,
        interval: ChartInterval,
        endingAt end: Date
    ) -> [BalanceSample] {
        let start = end.addingTimeInterval(-TimeInterval(interval.minutes * 60))
        return samples
            .filter {
                $0.currency.caseInsensitiveCompare(currency) == .orderedSame
                    && $0.timestamp >= start
                    && $0.timestamp <= end
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func bucketSize(for interval: ChartInterval) -> TimeInterval {
        switch interval.minutes {
        case ...5: 0
        case ...60: 5 * 60
        case ...1_440: 60 * 60
        default: 24 * 60 * 60
        }
    }

    private static func aggregate(_ samples: [BalanceSample], bucketSize: TimeInterval) -> [BalanceSample] {
        guard bucketSize > 0 else { return samples }
        let buckets = Dictionary(grouping: samples) { sample in
            Int(sample.timestamp.timeIntervalSince1970 / bucketSize)
        }
        return buckets.keys.sorted().flatMap { key -> [BalanceSample] in
            guard let bucket = buckets[key], let first = bucket.first, let last = bucket.last else { return [] }
            let minimum = bucket.min { $0.amount < $1.amount }!
            let maximum = bucket.max { $0.amount < $1.amount }!
            var selected = [first, minimum, maximum, last]
            selected.sort { $0.timestamp < $1.timestamp }

            var unique: [BalanceSample] = []
            for sample in selected where !unique.contains(sample) {
                unique.append(sample)
            }
            return unique
        }
    }

    private static func yDomain(_ values: [Double]) -> (min: Double, max: Double) {
        guard let low = values.min(), let high = values.max() else { return (0, 1) }
        let range = high - low
        if range < 0.000_001 {
            let padding = max(abs(low) * 0.005, 0.01)
            return (low - padding, high + padding)
        }
        let padding = max(range * 0.08, 0.005)
        return (low - padding, high + padding)
    }
}
