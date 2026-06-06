import AppKit
import Foundation

// MARK: - Popover View Controller
class PopoverViewController: NSViewController {
    // MARK: - UI Components
    private var contentView: NSView!
    private var chartContainer: NSView!
    private var balanceLabel: NSTextField!
    private var balanceValueLabel: NSTextField!
    private var balanceChangeLabel: NSTextField!
    private var topUpButton: NSButton!
    private var loadingSpinner: NSProgressIndicator!
    private var errorLabel: NSTextField!
    private var emptyLabel: NSTextField!
    private var intervalButtons: [NSButton] = []

    private let intervals: [(label: String, minutes: Int)] = [
        ("5分", 5), ("1时", 60), ("6时", 360), ("12时", 720), ("1天", 1440), ("7天", 10080),
    ]
    private var selectedIntervalIndex = 5
    private var rawHistory: [BalancePoint] = []
    private var currentBalanceValue: Double = 0

    // MARK: - Lifecycle
    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 370))
        self.view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
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
        titleLabel.frame = NSRect(x: 18, y: 330, width: 200, height: 22)
        root.addSubview(titleLabel)

        // Accent dot next to title
        let dot = NSView(frame: NSRect(x: 260, y: 338, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor(red: 0.3, green: 0.85, blue: 0.5, alpha: 1).cgColor
        root.addSubview(dot)

        // ── Balance Section ──
        let sectionIcon = makeLabel("💰", size: 13, weight: .regular, color: .white)
        sectionIcon.frame = NSRect(x: 18, y: 298, width: 22, height: 18)
        root.addSubview(sectionIcon)

        let balanceTitle = makeLabel("余额", size: 12, weight: .medium, color: NSColor(white: 0.75, alpha: 1))
        balanceTitle.frame = NSRect(x: 40, y: 298, width: 60, height: 18)
        root.addSubview(balanceTitle)

        // Balance value
        balanceValueLabel = makeLabel("加载中...", size: 26, weight: .bold, color: NSColor(red: 0.55, green: 1.0, blue: 0.7, alpha: 1))
        balanceValueLabel.frame = NSRect(x: 18, y: 258, width: 200, height: 34)
        root.addSubview(balanceValueLabel)

        // Top-up button
        topUpButton = makePillButton(title: "充值", color: NSColor(red: 0.35, green: 0.7, blue: 1.0, alpha: 0.9))
        topUpButton.frame = NSRect(x: 238, y: 266, width: 48, height: 22)
        topUpButton.target = self
        topUpButton.action = #selector(topUpClicked)
        root.addSubview(topUpButton)

        // Change indicator
        balanceChangeLabel = makeLabel("", size: 11, weight: .regular, color: NSColor(white: 0.55, alpha: 1))
        balanceChangeLabel.frame = NSRect(x: 18, y: 242, width: 260, height: 16)
        root.addSubview(balanceChangeLabel)

        // ── Separator ──
        addSeparator(y: 228, root: root)

        // ── Chart Section ──
        let chartIcon = makeLabel("📈", size: 12, weight: .regular, color: .white)
        chartIcon.frame = NSRect(x: 18, y: 208, width: 22, height: 16)
        root.addSubview(chartIcon)

        let chartTitle = makeLabel("余额变化", size: 12, weight: .medium, color: NSColor(white: 0.75, alpha: 1))
        chartTitle.frame = NSRect(x: 40, y: 208, width: 120, height: 16)
        root.addSubview(chartTitle)

        // ── Interval selector ──
        let pillW: CGFloat = 38
        let gap: CGFloat = 5
        let total = CGFloat(intervals.count) * pillW + CGFloat(intervals.count - 1) * gap
        let startX = (300 - total) / 2
        for (i, item) in intervals.enumerated() {
            let btn = makePillButton(title: item.label, color: NSColor(white: 0.5, alpha: 0.3))
            btn.frame = NSRect(x: startX + CGFloat(i) * (pillW + gap), y: 186, width: pillW, height: 18)
            btn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            btn.tag = i
            btn.target = self
            btn.action = #selector(intervalTapped(_:))
            root.addSubview(btn)
            intervalButtons.append(btn)
        }
        highlightInterval(at: selectedIntervalIndex)

        // ── Chart ──
        chartContainer = NSView(frame: NSRect(x: 14, y: 6, width: 272, height: 170))
        chartContainer.wantsLayer = true
        chartContainer.layer?.cornerRadius = 12
        chartContainer.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.55).cgColor
        chartContainer.layer?.borderColor = NSColor(white: 0.2, alpha: 0.4).cgColor
        chartContainer.layer?.borderWidth = 0.5
        root.addSubview(chartContainer)

        // Empty-state label
        emptyLabel = makeLabel("暂无数据\n使用后将自动记录余额变化", size: 11, weight: .regular, color: NSColor(white: 0.45, alpha: 1))
        emptyLabel.frame = NSRect(x: 14, y: 60, width: 272, height: 36)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        // Spinner
        loadingSpinner = NSProgressIndicator(frame: NSRect(x: 138, y: 100, width: 24, height: 24))
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isIndeterminate = true
        loadingSpinner.startAnimation(nil)
        loadingSpinner.isHidden = true
        root.addSubview(loadingSpinner)

        // Error label
        errorLabel = makeLabel("", size: 11, weight: .regular, color: NSColor(red: 1, green: 0.35, blue: 0.35, alpha: 1))
        errorLabel.frame = NSRect(x: 18, y: 16, width: 264, height: 16)
        errorLabel.isHidden = true
        root.addSubview(errorLabel)
    }

    // MARK: - Actions
    @objc private func topUpClicked() {
        if let url = URL(string: "https://platform.deepseek.com/top_up") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func intervalTapped(_ sender: NSButton) {
        guard sender.tag != selectedIntervalIndex else { return }
        selectedIntervalIndex = sender.tag
        highlightInterval(at: selectedIntervalIndex)
        refreshChart()
        updateChangeLabel()
    }

    // MARK: - Public API
    func showLoading() {
        loadViewIfNeeded()
        balanceValueLabel.stringValue = "加载中..."
        balanceChangeLabel.stringValue = ""
        errorLabel.isHidden = true
        emptyLabel.isHidden = true
        loadingSpinner.isHidden = false
        loadingSpinner.startAnimation(nil)
    }

    func updateBalance(_ balance: BalanceInfo?, history: [BalancePoint]) {
        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true
        rawHistory = history

        if let b = balance {
            currentBalanceValue = Double(b.totalBalance) ?? 0
            balanceValueLabel.stringValue = String(format: "¥ %.2f", currentBalanceValue)
        }
        updateChangeLabel()
        refreshChart()
    }

    private func updateChangeLabel() {
        let raw = rawWindowData()
        let intervalName = intervals[selectedIntervalIndex].label

        // Debug: log to file
        let debugMsg: String
        if raw.count >= 2 {
            let firstDate = raw.first!.date
            let lastDate = raw.last!.date
            let firstBal = raw.first!.balance
            let lastBal = raw.last!.balance
            let rawChg = lastBal - firstBal
            let withCurrent = currentBalanceValue - firstBal
            debugMsg = "[DEBUG] \(intervalName): raw pts=\(raw.count), first=\(firstDate) \(String(format: "%.2f", firstBal)), last=\(lastDate) \(String(format: "%.2f", lastBal)), rawΔ=\(String(format: "%.2f", rawChg)), withCurrentΔ=\(String(format: "%.2f", withCurrent)), currentBalanceValue=\(String(format: "%.2f", currentBalanceValue))"
        } else if raw.count == 1 {
            debugMsg = "[DEBUG] \(intervalName): only 1 raw pt: \(raw.first!.date) \(String(format: "%.2f", raw.first!.balance))"
        } else {
            debugMsg = "[DEBUG] \(intervalName): no raw data"
        }
        print(debugMsg)
        if let logURL = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("DeepSeekStats_debug.log") {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write((debugMsg + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? debugMsg.data(using: .utf8)?.write(to: logURL)
            }
        }

        if raw.count >= 2, let first = raw.first {
            let chg = currentBalanceValue - first.balance
            if chg < -0.01 {
                balanceChangeLabel.stringValue = "近\(intervalName)消费 ¥ \(String(format: "%.2f", abs(chg)))"
                balanceChangeLabel.textColor = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
            } else if chg > 0.01 {
                balanceChangeLabel.stringValue = "近\(intervalName)充值 ¥ \(String(format: "%.2f", chg))"
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

    func showBalanceError(_ err: String) {
        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true
        balanceValueLabel.stringValue = "加载失败"
        errorLabel.isHidden = false
        errorLabel.stringValue = err
    }

    // MARK: - Chart
    private func refreshChart() {
        let data = currentWindow()
        if data.count >= 2 {
            emptyLabel.isHidden = true
            drawChart(data)
        } else {
            emptyLabel.isHidden = false
            chartContainer.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
    }

    /// Raw (un-grouped) data points within the selected time window
    private func rawWindowData() -> [BalancePoint] {
        guard !rawHistory.isEmpty else { return [] }
        let mins = intervals[selectedIntervalIndex].minutes
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let cutoff = Calendar.current.date(byAdding: .minute, value: -mins, to: Date())!
        return rawHistory.filter { fmt.date(from: $0.date).map { $0 >= cutoff } ?? false }
            .sorted { $0.date < $1.date }
    }

    /// Grouped data for chart rendering
    /// - ≤1时: no grouping (raw points)
    /// - >1时 <1天: group by hour (e.g. "2026-06-05 14")
    /// - ≥1天: group by day (e.g. "2026-06-05")
    private func currentWindow() -> [(date: String, balance: Double)] {
        let pts = rawWindowData()
        guard !pts.isEmpty else { return [] }
        let mins = intervals[selectedIntervalIndex].minutes
        if mins <= 60 { return pts.map { ($0.date, $0.balance) } }

        let prefixLen = mins >= 1440 ? 10 : 13  // day-level vs hour-level grouping
        var grouped: [String: BalancePoint] = [:]
        for p in pts {
            let k = String(p.date.prefix(prefixLen))
            if grouped[k] == nil || p.date > grouped[k]!.date { grouped[k] = p }
        }
        return grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value.balance) }
    }

    private func drawChart(_ data: [(date: String, balance: Double)]) {
        chartContainer.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let container = chartContainer!
        let c = container.bounds.insetBy(dx: 4, dy: 6)

        // Plot area with balanced margins
        let pX: CGFloat = c.minX + 54                       // left edge (room for Y labels)
        let pY: CGFloat = c.minY + 22                       // bottom edge (room for X labels)
        let pW: CGFloat = max(c.width - 54 - 14, 20)        // plot width
        let pH: CGFloat = max(c.height - 22 - 14, 20)       // plot height (22 bottom + 14 top)

        let vals = data.map { $0.balance }
        let lo = vals.min()!, hi = vals.max()!
        let rng = max(hi - lo, 0.01)

        // ── Grid lines ──
        for frac: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let y = pY + frac * pH
            let line = CALayer()
            line.frame = NSRect(x: pX, y: y, width: pW, height: 0.5)
            line.backgroundColor = NSColor(white: 0.3, alpha: 0.12).cgColor
            container.layer?.addSublayer(line)

            let lbl = makeAxisLabel(String(format: "¥%.1f", lo + Double(frac) * Double(rng)), size: 10, color: .init(white: 0.55, alpha: 0.9))
            lbl.frame = NSRect(x: c.minX, y: y - 6, width: 44, height: 12)
            lbl.alignmentMode = .right
            container.layer?.addSublayer(lbl)
        }

        // ── X-axis time labels (based on selected window) ──
        let count = data.count
        guard count >= 2 else { return }
        let mins = intervals[selectedIntervalIndex].minutes

        // Window: from (now - mins) to now
        let windowEnd = Date()
        let windowStart = windowEnd.addingTimeInterval(-Double(mins) * 60)
        let totalSpan = Double(mins) * 60  // full window, not data range

        // Tick interval based on selected time span
        let tickInterval: TimeInterval
        if mins <= 5 { tickInterval = 60 }           // every 1 min
        else if mins <= 60 { tickInterval = 300 }     // every 5 min
        else if mins <= 1440 { tickInterval = 3600 }  // every 1 hour
        else { tickInterval = 86400 }                 // every 1 day

        // Round window start up to next clean tick boundary
        let startSec = windowStart.timeIntervalSinceReferenceDate
        let roundedStartSec = ceil(startSec / tickInterval) * tickInterval
        let roundedStart = Date(timeIntervalSinceReferenceDate: roundedStartSec)

        let tickFmt = DateFormatter()
        tickFmt.dateFormat = mins >= 1440 ? "MM/dd" : "HH:mm"

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

        // ── Build points ──
        var pts: [CGPoint] = []
        for (i, v) in vals.enumerated() {
            let x = pX + (CGFloat(i) / max(CGFloat(count - 1), 1)) * pW
            let y = pY + CGFloat((v - lo) / rng) * pH
            pts.append(CGPoint(x: x, y: y))
        }
        guard pts.count >= 2 else { return }

        // ── Smooth fill ──
        let fillPath = CGMutablePath()
        fillPath.move(to: CGPoint(x: pts[0].x, y: pY))
        for pt in pts { fillPath.addLine(to: pt) }
        fillPath.addLine(to: CGPoint(x: pts.last!.x, y: pY))
        fillPath.closeSubpath()

        let fill = CAShapeLayer()
        fill.path = fillPath
        fill.fillColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.18).cgColor
        container.layer?.addSublayer(fill)

        // ── Smooth curve (catmull-rom → bezier) ──
        let smoothPath = smoothedPath(pts)

        let line = CAShapeLayer()
        line.path = smoothPath
        line.strokeColor = NSColor(red: 0.35, green: 0.78, blue: 1.0, alpha: 0.85).cgColor
        line.lineWidth = 2
        line.fillColor = nil
        line.lineCap = .round
        line.lineJoin = .round
        container.layer?.addSublayer(line)

        // Glow behind the line
        let glow = CAShapeLayer()
        glow.path = smoothPath
        glow.strokeColor = NSColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 0.3).cgColor
        glow.lineWidth = 5
        glow.fillColor = nil
        glow.lineCap = .round
        glow.lineJoin = .round
        container.layer?.addSublayer(glow)

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
                // Outer glow ring on last dot
                let ring = CALayer()
                let rs: CGFloat = 10
                ring.frame = NSRect(x: pt.x - rs/2, y: pt.y - rs/2, width: rs, height: rs)
                ring.cornerRadius = rs / 2
                ring.backgroundColor = NSColor(red: 0.35, green: 0.78, blue: 1, alpha: 0.2).cgColor
                container.layer?.addSublayer(ring)
            }
            container.layer?.addSublayer(dot)
        }
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

    private func shortTime(_ s: String) -> String {
        if s.count >= 16 { return String(s.suffix(5)) }           // "yyyy-MM-dd HH:mm" → "HH:mm"
        if s.count >= 13 { return String(s.suffix(2)) + ":00" }   // "yyyy-MM-dd HH" → "HH:00"
        if s.count >= 10 {                                         // "yyyy-MM-dd" → "MM/dd"
            return String(s.suffix(5)).replacingOccurrences(of: "-", with: "/")
        }
        return s
    }

    private func addSeparator(y: CGFloat, root: NSView) {
        let sep = NSView(frame: NSRect(x: 18, y: y, width: 264, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.25).cgColor
        root.addSubview(sep)
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
