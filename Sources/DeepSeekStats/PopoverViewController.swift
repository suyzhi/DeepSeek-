import AppKit
import Foundation

// MARK: - Popover View Controller
class PopoverViewController: NSViewController {
    // MARK: - UI Components
    private var chartView: BalanceChartView!
    private var balanceValueLabel: NSTextField!
    private var balanceChangeLabel: NSTextField!
    private(set) var topUpButton: NSButton!
    private var loadingSpinner: NSProgressIndicator!
    private var errorLabel: NSTextField!
    private var emptyLabel: NSTextField!
    private(set) var intervalButtons: [NSButton] = []
    private var separatorLine: NSView!
    private var chartIconLabel: NSTextField!
    private var chartTitleLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var sectionIcon: NSTextField!
    private var balanceTitle: NSTextField!
    private var accentDot: NSView!
    private var refreshButton: NSButton!
    private var settingsButton: NSButton!
    private var isCompact = false
    private var isAnimatingCompactTransition = false

    private enum Layout {
        static let width: CGFloat = 300
        static let chartHeight: CGFloat = 170
        static let expandedHeight: CGFloat = 370
        static let compactHeight: CGFloat = 354
    }

    private lazy var todayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private lazy var shortDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onContentSizeChange: ((NSSize) -> Void)?

    private let intervals = ChartInterval.supported
    private var selectedIntervalIndex = 5
    private var rawHistory: [BalanceSample] = []
    private var currentSnapshot: BalanceSnapshot?

    /// Snapshot tests set this to `false` to capture a settled chart.
    var animatesChart = true

    // MARK: - Lifecycle
    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.expandedHeight))
        self.view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !isAnimatingCompactTransition else { return }
        relayout()
    }

    // MARK: - UI Build
    private func buildUI() {
        // ── Root ──
        let root = view
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true

        // Frosted glass background
        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.autoresizingMask = [.width, .height]
        root.addSubview(blur)

        // Dark overlay
        let overlay = NSView(frame: root.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.4).cgColor
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay, positioned: .above, relativeTo: blur)

        // ── Title ──
        let titleLabel = makeLabel("DeepSeek 用量", size: 15, weight: .semibold, color: .white)
        titleLabel.frame = NSRect(x: 18, y: 0, width: 200, height: 22)     // y set by relayout
        root.addSubview(titleLabel)
        self.titleLabel = titleLabel

        // Accent dot next to title
        let dot = NSView(frame: NSRect(x: 230, y: 0, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor(red: 0.3, green: 0.85, blue: 0.5, alpha: 1).cgColor
        root.addSubview(dot)
        accentDot = dot

        refreshButton = makeIconButton(symbol: "arrow.clockwise", fallback: "↻")
        refreshButton.frame = NSRect(x: 242, y: 0, width: 20, height: 20)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.toolTip = "立即刷新"
        root.addSubview(refreshButton)

        settingsButton = makeIconButton(symbol: "gearshape", fallback: "⚙")
        settingsButton.frame = NSRect(x: 268, y: 0, width: 20, height: 20)
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        settingsButton.toolTip = "设置"
        root.addSubview(settingsButton)

        // ── Balance Section ──
        let sectionIcon = makeLabel("💰", size: 13, weight: .regular, color: .white)
        sectionIcon.frame = NSRect(x: 18, y: 0, width: 22, height: 18)
        root.addSubview(sectionIcon)
        self.sectionIcon = sectionIcon

        let balanceTitle = makeLabel("余额", size: 12, weight: .medium, color: NSColor(white: 0.75, alpha: 1))
        balanceTitle.frame = NSRect(x: 40, y: 0, width: 190, height: 18)
        root.addSubview(balanceTitle)
        self.balanceTitle = balanceTitle

        // Balance value
        balanceValueLabel = makeLabel("加载中...", size: 26, weight: .bold, color: NSColor(red: 0.55, green: 1.0, blue: 0.7, alpha: 1))
        balanceValueLabel.frame = NSRect(x: 18, y: 0, width: 200, height: 34)
        root.addSubview(balanceValueLabel)

        // Top-up button
        topUpButton = makePillButton(title: "充值", color: NSColor(red: 0.35, green: 0.7, blue: 1.0, alpha: 0.9))
        topUpButton.frame = NSRect(x: 238, y: 0, width: 48, height: 22)
        topUpButton.target = self
        topUpButton.action = #selector(topUpClicked)
        root.addSubview(topUpButton)

        // Change indicator
        balanceChangeLabel = makeLabel("", size: 11, weight: .regular, color: NSColor(white: 0.55, alpha: 1))
        balanceChangeLabel.frame = NSRect(x: 18, y: 0, width: 260, height: 16)
        root.addSubview(balanceChangeLabel)

        // ── Separator ──
        addSeparator(y: 0, root: root)

        // ── Chart Section ──
        let chartIcon = makeLabel("📈", size: 12, weight: .regular, color: .white)
        chartIcon.frame = NSRect(x: 18, y: 0, width: 22, height: 16)
        root.addSubview(chartIcon)
        chartIconLabel = chartIcon

        let chartTitle = makeLabel("余额变化", size: 12, weight: .medium, color: NSColor(white: 0.75, alpha: 1))
        chartTitle.frame = NSRect(x: 40, y: 0, width: 120, height: 16)
        root.addSubview(chartTitle)
        chartTitleLabel = chartTitle

        // ── Interval selector ──
        let pillW: CGFloat = 38
        let gap: CGFloat = 5
        let total = CGFloat(intervals.count) * pillW + CGFloat(intervals.count - 1) * gap
        let startX = (Layout.width - total) / 2
        for (i, item) in intervals.enumerated() {
            let btn = makePillButton(title: item.label, color: NSColor(white: 0.5, alpha: 0.3))
            btn.frame = NSRect(x: startX + CGFloat(i) * (pillW + gap), y: 0, width: pillW, height: 18)
            btn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            btn.tag = i
            btn.target = self
            btn.action = #selector(intervalTapped(_:))
            root.addSubview(btn)
            intervalButtons.append(btn)
        }
        highlightInterval(at: selectedIntervalIndex)

        // ── Chart ──
        chartView = BalanceChartView(frame: NSRect(x: 14, y: 0, width: 272, height: Layout.chartHeight))
        root.addSubview(chartView)

        // Empty-state label
        emptyLabel = makeLabel("暂无数据\n使用后将自动记录余额变化", size: 11, weight: .regular, color: NSColor(white: 0.45, alpha: 1))
        emptyLabel.frame = NSRect(x: 14, y: 0, width: 272, height: 36)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        // Spinner
        loadingSpinner = NSProgressIndicator(frame: NSRect(x: 138, y: 0, width: 24, height: 24))
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isIndeterminate = true
        loadingSpinner.startAnimation(nil)
        loadingSpinner.isHidden = true
        root.addSubview(loadingSpinner)

        // Error label
        errorLabel = makeLabel("", size: 11, weight: .regular, color: NSColor(red: 1, green: 0.35, blue: 0.35, alpha: 1))
        errorLabel.frame = NSRect(x: 18, y: 0, width: 264, height: 16)
        errorLabel.isHidden = true
        root.addSubview(errorLabel)

        // Apply dynamic layout
        relayout()
    }

    // MARK: - Actions
    @objc private func topUpClicked() {
        if let url = URL(string: "https://platform.deepseek.com/top_up") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func refreshClicked() {
        onRefresh?()
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    @objc private func intervalTapped(_ sender: NSButton) {
        guard sender.tag != selectedIntervalIndex else { return }
        selectedIntervalIndex = sender.tag
        highlightInterval(at: selectedIntervalIndex)
        refreshChart()
        updateChangeLabel()
    }

    // MARK: - Public API
    func render(_ state: BalanceViewState) {
        loadViewIfNeeded()
        errorLabel.isHidden = true
        switch state {
        case .loading(let previous):
            loadingSpinner.isHidden = false
            loadingSpinner.startAnimation(nil)
            refreshButton.isEnabled = false
            refreshButton.toolTip = "立即刷新"
            if let previous {
                currentSnapshot = previous
                balanceValueLabel.stringValue = MoneyFormatter.string(
                    amount: previous.amount,
                    currency: previous.currency
                )
                balanceTitle.stringValue = "余额 · 正在刷新"
            } else {
                balanceValueLabel.stringValue = "加载中..."
                balanceTitle.stringValue = "余额"
                balanceChangeLabel.stringValue = ""
            }

        case .fresh(let snapshot, let history):
            stopLoading()
            apply(snapshot: snapshot, history: history)
            balanceTitle.stringValue = "余额 · 更新于 \(timeString(snapshot.fetchedAt))"
            refreshButton.toolTip = "立即刷新"

        case .stale(let snapshot, let history, let error):
            stopLoading()
            apply(snapshot: snapshot, history: history)
            balanceTitle.stringValue = "余额 · 离线缓存 \(timeString(snapshot.fetchedAt))"
            refreshButton.toolTip = error.localizedDescription

        case .failed(let error):
            stopLoading()
            currentSnapshot = nil
            rawHistory = []
            balanceValueLabel.stringValue = "加载失败"
            balanceTitle.stringValue = "余额"
            balanceChangeLabel.stringValue = ""
            errorLabel.isHidden = false
            errorLabel.stringValue = error.localizedDescription
            refreshChart()
        }
    }

    private func stopLoading() {
        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true
        refreshButton.isEnabled = true
    }

    private func apply(snapshot: BalanceSnapshot, history: [BalanceSample]) {
        currentSnapshot = snapshot
        rawHistory = history
        balanceValueLabel.stringValue = MoneyFormatter.string(
            amount: snapshot.amount,
            currency: snapshot.currency
        )
        updateChangeLabel()
        refreshChart()
    }

    private func updateChangeLabel() {
        guard let snapshot = currentSnapshot else {
            balanceChangeLabel.stringValue = ""
            setCompactMode(true)
            return
        }

        let intervalName = intervals[selectedIntervalIndex].label
        let change = BalanceChangeCalculator.compute(
            snapshot: snapshot,
            windowSamples: rawWindowData()
        )
        setCompactMode(!change.isMeaningful)

        switch change {
        case .none:
            balanceChangeLabel.stringValue = ""
        case .unchanged:
            balanceChangeLabel.stringValue = "近\(intervalName)无变动"
            balanceChangeLabel.textColor = NSColor(white: 0.55, alpha: 1)
        case .spent(let amount):
            balanceChangeLabel.stringValue = "近\(intervalName)消费 \(MoneyFormatter.string(amount: amount, currency: snapshot.currency))"
            balanceChangeLabel.textColor = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
        case .toppedUp(let amount):
            balanceChangeLabel.stringValue = "近\(intervalName)充值 \(MoneyFormatter.string(amount: amount, currency: snapshot.currency))"
            balanceChangeLabel.textColor = NSColor(red: 0.4, green: 1, blue: 0.5, alpha: 1)
        }
    }

    // MARK: - Chart
    private func refreshChart() {
        if let snapshot = currentSnapshot,
           let series = currentWindow(),
           series.points.count >= 2 {
            emptyLabel.isHidden = true
            chartView.render(series, currency: snapshot.currency, animated: animatesChart)
        } else {
            emptyLabel.isHidden = false
            chartView.clear()
        }
    }

    /// Raw (un-grouped) data points within the selected time window.
    private func rawWindowData() -> [BalanceSample] {
        guard let snapshot = currentSnapshot else { return [] }
        return ChartSeriesBuilder.windowedSamples(
            samples: rawHistory,
            currency: snapshot.currency,
            interval: intervals[selectedIntervalIndex],
            endingAt: Date()
        )
    }

    /// Grouped data for chart rendering
    /// - ≤1时: no grouping (raw points)
    /// - >1时 <1天: group by hour (e.g. "2026-06-05 14")
    /// - ≥1天: group by day (e.g. "2026-06-05")
    /// - Each group keeps first AND last point to preserve the full value range
    private func currentWindow() -> ChartSeries? {
        guard let snapshot = currentSnapshot else { return nil }
        return ChartSeriesBuilder.build(
            samples: rawHistory,
            currency: snapshot.currency,
            interval: intervals[selectedIntervalIndex],
            endingAt: Date()
        )
    }

    // MARK: - Helpers

    /// Dynamic layout: positions all subviews bottom-up based on view bounds and compact mode.
    /// Called from viewDidLayout() and whenever isCompact / view size changes.
    private func relayout() {
        let h = view.bounds.height
        guard h >= 300 else { return }  // sanity guard during initial setup
        let bottomPad: CGFloat = isCompact ? 14 : 6

        var y: CGFloat = bottomPad

        // Chart
        chartView.frame.origin.y = y
        y += Layout.chartHeight

        // Interval buttons
        y += 10
        for btn in intervalButtons {
            btn.frame.origin.y = y
        }
        y += 18

        // Chart icon + title
        y += 4
        chartIconLabel.frame.origin.y = y
        chartTitleLabel.frame.origin.y = y
        y += 16

        // Separator
        y += 4
        separatorLine.frame.origin.y = y
        y += 1

        // Balance change label (hidden in compact)
        y += 13
        if !isCompact {
            balanceChangeLabel.frame.origin.y = y
            y += 16
        }
        // 0pt gap — balanceValueLabel starts right after changeLabel

        // Balance value + top-up button
        balanceValueLabel.frame.origin.y = y
        topUpButton.frame.origin.y = y + 8  // vertically centered within balance value area
        y += 34

        // Section icon + title
        y += 6
        sectionIcon.frame.origin.y = y
        balanceTitle.frame.origin.y = y
        y += 18

        // Title + accent dot
        y += 14
        titleLabel.frame.origin.y = y
        accentDot.frame.origin.y = y + 8
        refreshButton.frame.origin.y = y + 1
        settingsButton.frame.origin.y = y + 1
        y += 22

        // y now equals view.bounds.height - topPadding (computed from isCompact)
    }

    private func setCompactMode(_ compact: Bool) {
        guard isCompact != compact else { return }
        var transitionViews: [NSView] = []
        transitionViews.append(chartView)
        transitionViews.append(chartIconLabel)
        transitionViews.append(chartTitleLabel)
        transitionViews.append(separatorLine)
        transitionViews.append(balanceChangeLabel)
        transitionViews.append(balanceValueLabel)
        transitionViews.append(topUpButton)
        transitionViews.append(sectionIcon)
        transitionViews.append(balanceTitle)
        transitionViews.append(titleLabel)
        transitionViews.append(accentDot)
        transitionViews.append(refreshButton)
        transitionViews.append(settingsButton)
        transitionViews.append(contentsOf: intervalButtons)
        let originalFrames = transitionViews.map(\.frame)

        isCompact = compact
        isAnimatingCompactTransition = true

        // Calculate the target layout, then restore the current frames so AppKit
        // can interpolate every element instead of jumping to its new position.
        relayout()
        let targetFrames = transitionViews.map(\.frame)
        for (subview, frame) in zip(transitionViews, originalFrames) {
            subview.frame = frame
        }

        if !compact {
            balanceChangeLabel.isHidden = false
            balanceChangeLabel.alphaValue = 0
        }

        let targetSize = NSSize(width: Layout.width, height: compact ? Layout.compactHeight : Layout.expandedHeight)
        preferredContentSize = targetSize
        onContentSizeChange?(targetSize)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            for (subview, frame) in zip(transitionViews, targetFrames) {
                subview.animator().frame = frame
            }
            balanceChangeLabel.animator().alphaValue = compact ? 0 : 1
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.balanceChangeLabel.isHidden = compact
                self.balanceChangeLabel.alphaValue = 1
                self.isAnimatingCompactTransition = false
                self.relayout()
            }
        }
    }

    private func highlightInterval(at idx: Int) {
        for (i, btn) in intervalButtons.enumerated() {
            let selected = i == idx
            let pStyle = NSMutableParagraphStyle(); pStyle.alignment = .center
            btn.attributedTitle = NSAttributedString(
                string: btn.title,
                attributes: [
                    .foregroundColor: selected ? NSColor.white : NSColor(white: 0.6, alpha: 1),
                    .font: NSFont.systemFont(ofSize: 9, weight: selected ? .semibold : .regular),
                    .paragraphStyle: pStyle,
                ])
            btn.layer?.backgroundColor = selected
                ? NSColor(red: 0.3, green: 0.6, blue: 1, alpha: 0.7).cgColor
                : NSColor(white: 0.15, alpha: 0.6).cgColor
        }
    }

    private func addSeparator(y: CGFloat, root: NSView) {
        let sep = NSView(frame: NSRect(x: 18, y: y, width: 264, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.25).cgColor
        root.addSubview(sep)
        separatorLine = sep
    }

    /// The pill is drawn entirely by the layer: a bordered bezel would stack a
    /// second rounded background on top of it and steal ~22pt of label width.
    private func makePillButton(title: String, color: NSColor) -> NSButton {
        let btn = PillButton(frame: .zero)
        btn.title = title
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 5
        btn.layer?.backgroundColor = color.cgColor
        btn.focusRingType = .none
        let ps = NSMutableParagraphStyle(); ps.alignment = .center
        btn.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .paragraphStyle: ps]
        )
        return btn
    }

    private func makeIconButton(symbol: String, fallback: String) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.focusRingType = .none
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor(white: 0.78, alpha: 1)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: fallback) {
            button.image = image
        } else {
            button.title = fallback
        }
        return button
    }

    private func timeString(_ date: Date) -> String {
        let formatter = Calendar.current.isDateInToday(date) ? todayTimeFormatter : shortDateTimeFormatter
        return formatter.string(from: date)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.backgroundColor = .clear
        l.isBezeled = false
        l.isEditable = false
        return l
    }

}
