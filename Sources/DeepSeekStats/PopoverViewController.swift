import AppKit
import Foundation

// MARK: - Popover View Controller
class PopoverViewController: NSViewController {
    // MARK: - UI Components
    private var chartContainer: NSView!
    private var balanceValueLabel: NSTextField!
    private var balanceChangeLabel: NSTextField!
    private var topUpButton: NSButton!
    private var loadingSpinner: NSProgressIndicator!
    private var errorLabel: NSTextField!
    private var emptyLabel: NSTextField!
    private var intervalButtons: [NSButton] = []
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
    private var previousLinePath: CGPath?
    private var previousPointCount = 0
    private var isAnimatingCompactTransition = false

    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onContentSizeChange: ((NSSize) -> Void)?

    private let intervals = ChartInterval.supported
    private var selectedIntervalIndex = 5
    private var rawHistory: [BalanceSample] = []
    private var currentSnapshot: BalanceSnapshot?

    // MARK: - Lifecycle
    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 370))
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
        let startX = (300 - total) / 2
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
        chartContainer = NSView(frame: NSRect(x: 14, y: 0, width: 272, height: 170))
        chartContainer.wantsLayer = true
        chartContainer.layer?.cornerRadius = 12
        chartContainer.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.55).cgColor
        chartContainer.layer?.borderColor = NSColor(white: 0.2, alpha: 0.4).cgColor
        chartContainer.layer?.borderWidth = 0.5
        root.addSubview(chartContainer)

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
        let raw = rawWindowData()
        let intervalName = intervals[selectedIntervalIndex].label

        // Determine if there's meaningful change
        let hasChange: Bool
        guard let snapshot = currentSnapshot else {
            balanceChangeLabel.stringValue = ""
            setCompactMode(true)
            return
        }
        let currentBalanceValue = decimalDouble(snapshot.amount)
        if raw.count >= 2, let first = raw.first {
            hasChange = abs(currentBalanceValue - decimalDouble(first.amount)) >= 0.01
        } else {
            hasChange = false
        }
        setCompactMode(!hasChange)

        if raw.count >= 2, let first = raw.first {
            let chg = currentBalanceValue - decimalDouble(first.amount)
            let formatted = MoneyFormatter.string(
                amount: Decimal(abs(chg)),
                currency: snapshot.currency
            )
            if chg < -0.01 {
                balanceChangeLabel.stringValue = "近\(intervalName)消费 \(formatted)"
                balanceChangeLabel.textColor = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
            } else if chg > 0.01 {
                balanceChangeLabel.stringValue = "近\(intervalName)充值 \(formatted)"
                balanceChangeLabel.textColor = NSColor(red: 0.4, green: 1, blue: 0.5, alpha: 1)
            } else {
                balanceChangeLabel.stringValue = "近\(intervalName)无变动"
                balanceChangeLabel.textColor = NSColor(white: 0.55, alpha: 1)
            }
        } else if raw.count == 1 {
            balanceChangeLabel.stringValue = "近\(intervalName)无变动"
            balanceChangeLabel.textColor = NSColor(white: 0.55, alpha: 1)
        } else {
            balanceChangeLabel.stringValue = ""
        }
    }

    // MARK: - Chart
    private func refreshChart() {
        if let series = currentWindow(), series.points.count >= 2 {
            emptyLabel.isHidden = true
            // Capture old chart as bitmap for crossfade
            let snapshot = captureChartBitmap()
            drawChart(series, oldSnapshot: snapshot)
        } else {
            emptyLabel.isHidden = false
            chartContainer.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            previousLinePath = nil
            previousPointCount = 0
        }
    }

    /// Raw (un-grouped) data points within the selected time window
    private func rawWindowData() -> [BalanceSample] {
        guard let snapshot = currentSnapshot else { return [] }
        let cutoff = Date().addingTimeInterval(-TimeInterval(intervals[selectedIntervalIndex].minutes * 60))
        return rawHistory.filter {
            $0.currency.caseInsensitiveCompare(snapshot.currency) == .orderedSame
                && $0.timestamp >= cutoff
        }.sorted { $0.timestamp < $1.timestamp }
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

    private func drawChart(_ series: ChartSeries, oldSnapshot: CGImage?) {
        chartContainer.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let container = chartContainer!
        let c = container.bounds.insetBy(dx: 4, dy: 6)

        // Plot area with balanced margins
        let pX: CGFloat = c.minX + 54                       // left edge (room for Y labels)
        let pY: CGFloat = c.minY + 22                       // bottom edge (room for X labels)
        let pW: CGFloat = max(c.width - 54 - 14, 20)        // plot width
        let pH: CGFloat = max(c.height - 22 - 14, 20)       // plot height (22 bottom + 14 top)

        let vals = series.points.map { decimalDouble($0.amount) }
        let lo = series.minimum
        let hi = series.maximum
        let rng = max(hi - lo, 0.000_001)

        // ── Time window params (used by both X-axis labels AND data points) ──
        guard series.points.count >= 2 else { return }
        let windowEnd = series.end
        let windowStart = series.start
        let startSec = windowStart.timeIntervalSinceReferenceDate
        let totalSpan = max(windowEnd.timeIntervalSince(windowStart), 1)

        // ── Grid lines ──
        for frac: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let y = pY + frac * pH
            let line = CALayer()
            line.frame = NSRect(x: pX, y: y, width: pW, height: 0.5)
            line.backgroundColor = NSColor(white: 0.3, alpha: 0.12).cgColor
            container.layer?.addSublayer(line)

            let amount = Decimal(lo + Double(frac) * rng)
            let label = currentSnapshot.map {
                MoneyFormatter.string(amount: amount, currency: $0.currency, fractionDigits: 1)
            } ?? String(format: "%.1f", NSDecimalNumber(decimal: amount).doubleValue)
            let lbl = makeAxisLabel(label, size: 10, color: .init(white: 0.55, alpha: 0.9))
            lbl.frame = NSRect(x: c.minX, y: y - 6, width: pX - c.minX - 4, height: 12)
            lbl.alignmentMode = .left
            container.layer?.addSublayer(lbl)
        }

        // ── X-axis time labels (based on selected window) ──

        // Tick interval based on selected time span
        let tickInterval: TimeInterval
        let displayedMinutes = totalSpan / 60
        if displayedMinutes <= 5 { tickInterval = 60 }           // every 1 min
        else if displayedMinutes <= 60 { tickInterval = 300 }     // every 5 min
        else if displayedMinutes <= 1440 { tickInterval = 3600 }  // every 1 hour
        else { tickInterval = 86400 }                 // every 1 day

        // Round window start up to next clean tick boundary
        let roundedStartSec = ceil(startSec / tickInterval) * tickInterval
        let roundedStart = Date(timeIntervalSinceReferenceDate: roundedStartSec)

        let tickFmt = DateFormatter()
        tickFmt.dateFormat = displayedMinutes > 1440 ? "MM/dd" : "HH:mm"

        var tickDate = roundedStart
        var lastLabelX: CGFloat = -.infinity
        let minLabelSpacing: CGFloat = 40
        while tickDate <= windowEnd {
            let fraction = (tickDate.timeIntervalSinceReferenceDate - startSec) / totalSpan
            let x = pX + CGFloat(max(0, fraction)) * pW
            // Skip first (overlaps Y-axis) or too close to previous
            if x > pX + 5 && x - lastLabelX >= minLabelSpacing {
                let lbl = makeAxisLabel(tickFmt.string(from: tickDate), size: 9, color: .init(white: 0.55, alpha: 0.9))
                lbl.frame = NSRect(x: x - 18, y: pY - 18, width: 36, height: 12)
                lbl.alignmentMode = .center
                container.layer?.addSublayer(lbl)
                lastLabelX = x
            }
            tickDate = tickDate.addingTimeInterval(tickInterval)
        }

        // ── Build points using their actual timestamp within the selected window ──
        var pts: [CGPoint] = []
        for (i, v) in vals.enumerated() {
            let fraction = series.xFraction(for: series.points[i].timestamp)
            let x = pX + CGFloat(fraction) * pW
            let y = pY + CGFloat((v - lo) / rng) * pH
            pts.append(CGPoint(x: x, y: y))
        }
        guard pts.count >= 2 else { return }

        // ── Curve layer (separate from grid, for independent animation) ──
        let curveLayer = CALayer()
        curveLayer.frame = container.bounds
        container.layer?.addSublayer(curveLayer)

        // ── Vertical drop lines (fade in after curve morph) ──
        let dropLayer = CALayer()
        dropLayer.frame = container.bounds
        dropLayer.opacity = 0
        curveLayer.addSublayer(dropLayer)

        for pt in pts {
            let dh = max(0, pt.y - pY)
            let dl = CALayer()
            dl.frame = NSRect(x: pt.x - 0.5, y: pY, width: 1, height: dh)
            dl.backgroundColor = NSColor(white: 0.45, alpha: 0.12).cgColor
            dropLayer.addSublayer(dl)
        }

        let dropFade = CABasicAnimation(keyPath: "opacity")
        dropFade.fromValue = 0
        dropFade.toValue = 1.0
        dropFade.duration = 0.35
        dropFade.beginTime = CACurrentMediaTime() + 0.45
        dropFade.fillMode = .forwards
        dropFade.isRemovedOnCompletion = false
        dropLayer.add(dropFade, forKey: "dropFade")

        // ── Smooth curve ──
        let smoothPath = smoothedPath(pts)

        let line = CAShapeLayer()
        line.path = smoothPath
        line.strokeColor = NSColor(red: 0.35, green: 0.78, blue: 1.0, alpha: 0.85).cgColor
        line.lineWidth = 2
        line.fillColor = nil
        line.lineCap = .round
        line.lineJoin = .round
        curveLayer.addSublayer(line)

        // Morph from the previous curve when its structure is compatible.
        // On first render or after the point count changes, rise from a
        // point-compatible baseline instead of attempting an invalid morph.
        let baselinePoints = pts.map { CGPoint(x: $0.x, y: pY) }
        let animationStartPath: CGPath
        if let prevLine = previousLinePath, previousPointCount == pts.count {
            animationStartPath = prevLine
        } else {
            animationStartPath = smoothedPath(baselinePoints)
        }

        let morph = CABasicAnimation(keyPath: "path")
        morph.fromValue = animationStartPath
        morph.toValue = smoothPath
        morph.duration = 0.55
        morph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        line.add(morph, forKey: "curveMorph")
        previousLinePath = smoothPath
        previousPointCount = pts.count

        // ── Smooth fill (wipe from top to bottom after curve morph) ──
        let fillPath = CGMutablePath()
        fillPath.move(to: CGPoint(x: pts[0].x, y: pY))
        for pt in pts { fillPath.addLine(to: pt) }
        fillPath.addLine(to: CGPoint(x: pts.last!.x, y: pY))
        fillPath.closeSubpath()

        // Start shape: collapsed to a thin strip at the bottom
        let startPath = CGMutablePath()
        startPath.move(to: CGPoint(x: pX, y: pY))
        startPath.addLine(to: CGPoint(x: pX, y: pY + 1))
        for pt in pts.dropFirst() {
            startPath.addLine(to: CGPoint(x: pt.x, y: pY + 1))
        }
        startPath.addLine(to: CGPoint(x: pX + pW, y: pY))
        startPath.closeSubpath()

        let fill = CAShapeLayer()
        fill.path = startPath
        fill.fillColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.15).cgColor
        curveLayer.addSublayer(fill)

        let wipeAnim = CABasicAnimation(keyPath: "path")
        wipeAnim.fromValue = startPath
        wipeAnim.toValue = fillPath
        wipeAnim.duration = 0.4
        wipeAnim.beginTime = CACurrentMediaTime() + 0.45
        wipeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wipeAnim.fillMode = .forwards
        wipeAnim.isRemovedOnCompletion = false
        fill.add(wipeAnim, forKey: "fillWipe")

        // Glow behind the line — fade in after curve morph completes
        let glow = CAShapeLayer()
        glow.path = smoothPath
        glow.strokeColor = NSColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 0.15).cgColor
        glow.lineWidth = 4
        glow.fillColor = nil
        glow.lineCap = .round
        glow.lineJoin = .round
        glow.opacity = 0
        curveLayer.addSublayer(glow)

        let glowFade = CABasicAnimation(keyPath: "opacity")
        glowFade.fromValue = 0
        glowFade.toValue = 1.0
        glowFade.duration = 0.35
        glowFade.beginTime = CACurrentMediaTime() + 0.45
        glowFade.fillMode = .forwards
        glowFade.isRemovedOnCompletion = false
        glow.add(glowFade, forKey: "glowFade")

        // ── Dots ──
        for (i, pt) in pts.enumerated() {
            let isLast = i == pts.count - 1
            let dot = CALayer()
            let sz: CGFloat = isLast ? 6 : 2.5
            dot.frame = NSRect(x: pt.x - sz/2, y: pt.y - sz/2, width: sz, height: sz)
            dot.cornerRadius = sz / 2
            dot.backgroundColor = isLast
                ? NSColor(red: 0.4, green: 0.85, blue: 1, alpha: 1).cgColor
                : NSColor(white: 0.85, alpha: 0.6).cgColor

            if isLast {
                let ring = CALayer()
                let rs: CGFloat = 10
                ring.frame = NSRect(x: pt.x - rs/2, y: pt.y - rs/2, width: rs, height: rs)
                ring.cornerRadius = rs / 2
                ring.backgroundColor = NSColor(red: 0.35, green: 0.78, blue: 1, alpha: 0.2).cgColor
                curveLayer.addSublayer(ring)
            }
            curveLayer.addSublayer(dot)
        }

        // ── Crossfade: old snapshot fades out ──
        if let snap = oldSnapshot {
            let snapLayer = CALayer()
            snapLayer.contents = snap
            snapLayer.frame = container.bounds
            container.layer?.addSublayer(snapLayer)

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1.0
            fadeOut.toValue = 0.0
            fadeOut.duration = 0.5
            fadeOut.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fadeOut.isRemovedOnCompletion = false
            fadeOut.fillMode = .forwards
            CATransaction.begin()
            CATransaction.setCompletionBlock { snapLayer.removeFromSuperlayer() }
            snapLayer.add(fadeOut, forKey: nil)
            CATransaction.commit()
        }

        // Subtle pop on new curve
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.93, 1.0]
        pop.keyTimes = [0, 1]
        pop.duration = 0.5
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        curveLayer.add(pop, forKey: "chartPop")
    }

    /// Capture current chart content as bitmap for crossfade
    private func captureChartBitmap() -> CGImage? {
        guard let layer = chartContainer?.layer, let subs = layer.sublayers, !subs.isEmpty else { return nil }
        let bounds = layer.bounds
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale)
        let h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// Straight line segments
    private func smoothedPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard pts.count >= 1 else { return path }
        path.move(to: pts[0])
        for i in 1..<pts.count {
            path.addLine(to: pts[i])
        }
        return path
    }

    // MARK: - Helpers

    /// Dynamic layout: positions all subviews bottom-up based on view bounds and compact mode.
    /// Called from viewDidLayout() and whenever isCompact / view size changes.
    private func relayout() {
        let h = view.bounds.height
        guard h >= 300 else { return }  // sanity guard during initial setup
        let bottomPad: CGFloat = isCompact ? 14 : 6

        var y: CGFloat = bottomPad

        // Chart container
        chartContainer.frame.origin.y = y
        y += 170

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
        transitionViews.append(chartContainer)
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

        let targetSize = NSSize(width: 300, height: compact ? 354 : 370)
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

    private func makePillButton(title: String, color: NSColor) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.title = title
        btn.bezelStyle = .rounded
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func decimalDouble(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
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

    private func makeAxisLabel(_ text: String, size: CGFloat, color: NSColor) -> CATextLayer {
        let l = CATextLayer()
        l.string = text
        l.fontSize = size
        l.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        l.foregroundColor = color.cgColor
        l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        return l
    }
}
