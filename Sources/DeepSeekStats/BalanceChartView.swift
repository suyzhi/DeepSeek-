import AppKit
import Foundation

/// Renders the balance curve, its axes and the entry animations.
///
/// Extracted from `PopoverViewController` so the controller only owns layout,
/// interval selection and view state; this view knows nothing about networking
/// or the history store.
final class BalanceChartView: NSView {
    private var previousLinePath: CGPath?
    private var previousPointCount = 0
    private var screenScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    private lazy var tickDateFormatter = DateFormatter()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.55).cgColor
        layer?.borderColor = NSColor(white: 0.2, alpha: 0.4).cgColor
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        screenScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? screenScale
    }

    /// Draws `series`, crossfading out the previously rendered chart.
    ///
    /// - Parameter animated: pass `false` to draw the settled chart immediately.
    ///   Entry animations are also skipped when the system asks for reduced motion.
    func render(_ series: ChartSeries, currency: String, animated: Bool = true) {
        let useAnimations = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let oldSnapshot = useAnimations ? captureChartBitmap() : nil
        drawChart(series, currency: currency, oldSnapshot: oldSnapshot, animated: useAnimations)
    }

    /// Clears the chart and forgets the morph baseline.
    func clear() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        previousLinePath = nil
        previousPointCount = 0
    }

    // MARK: - Drawing
    private func drawChart(_ series: ChartSeries, currency: String, oldSnapshot: CGImage?, animated: Bool) {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let c = bounds.insetBy(dx: 4, dy: 6)

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
        let gridFractions: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        let axisDigits = axisFractionDigits(range: rng, steps: gridFractions.count - 1)
        for frac in gridFractions {
            let y = pY + frac * pH
            let line = CALayer()
            line.frame = NSRect(x: pX, y: y, width: pW, height: 0.5)
            line.backgroundColor = NSColor(white: 0.3, alpha: 0.12).cgColor
            layer?.addSublayer(line)

            let amount = Decimal(lo + Double(frac) * rng)
            let lbl = makeAxisLabel(
                MoneyFormatter.string(amount: amount, currency: currency, fractionDigits: axisDigits),
                size: 10,
                color: .init(white: 0.55, alpha: 0.9)
            )
            lbl.frame = NSRect(x: c.minX, y: y - 6, width: pX - c.minX - 4, height: 12)
            lbl.alignmentMode = .left
            layer?.addSublayer(lbl)
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

        tickDateFormatter.dateFormat = displayedMinutes > 1440 ? "MM/dd" : "HH:mm"

        var tickDate = roundedStart
        var lastLabelX: CGFloat = -.infinity
        let minLabelSpacing: CGFloat = 40
        while tickDate <= windowEnd {
            let fraction = (tickDate.timeIntervalSinceReferenceDate - startSec) / totalSpan
            let x = pX + CGFloat(max(0, fraction)) * pW
            // Skip first (overlaps Y-axis) or too close to previous
            if x > pX + 5 && x - lastLabelX >= minLabelSpacing {
                let lbl = makeAxisLabel(tickDateFormatter.string(from: tickDate), size: 9, color: .init(white: 0.55, alpha: 0.9))
                lbl.frame = NSRect(x: x - 18, y: pY - 18, width: 36, height: 12)
                lbl.alignmentMode = .center
                layer?.addSublayer(lbl)
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
        curveLayer.frame = bounds
        layer?.addSublayer(curveLayer)

        // ── Vertical drop lines (fade in after curve morph) ──
        let dropLayer = CALayer()
        dropLayer.frame = bounds
        dropLayer.opacity = animated ? 0 : 1
        curveLayer.addSublayer(dropLayer)

        for pt in pts {
            let dh = max(0, pt.y - pY)
            let dl = CALayer()
            dl.frame = NSRect(x: pt.x - 0.5, y: pY, width: 1, height: dh)
            dl.backgroundColor = NSColor(white: 0.45, alpha: 0.12).cgColor
            dropLayer.addSublayer(dl)
        }

        if animated {
            let dropFade = CABasicAnimation(keyPath: "opacity")
            dropFade.fromValue = 0
            dropFade.toValue = 1.0
            dropFade.duration = 0.35
            dropFade.beginTime = CACurrentMediaTime() + 0.45
            dropFade.fillMode = .forwards
            dropFade.isRemovedOnCompletion = false
            dropLayer.add(dropFade, forKey: "dropFade")
        }

        // ── Curve ──
        let curvePath = polylinePath(pts)

        let line = CAShapeLayer()
        line.path = curvePath
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
            animationStartPath = polylinePath(baselinePoints)
        }

        if animated {
            let morph = CABasicAnimation(keyPath: "path")
            morph.fromValue = animationStartPath
            morph.toValue = curvePath
            morph.duration = 0.55
            morph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            line.add(morph, forKey: "curveMorph")
        }
        previousLinePath = curvePath
        previousPointCount = pts.count

        // ── Fill (wipe from top to bottom after curve morph) ──
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
        fill.path = animated ? startPath : fillPath
        fill.fillColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.15).cgColor
        curveLayer.addSublayer(fill)

        if animated {
            let wipeAnim = CABasicAnimation(keyPath: "path")
            wipeAnim.fromValue = startPath
            wipeAnim.toValue = fillPath
            wipeAnim.duration = 0.4
            wipeAnim.beginTime = CACurrentMediaTime() + 0.45
            wipeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wipeAnim.fillMode = .forwards
            wipeAnim.isRemovedOnCompletion = false
            fill.add(wipeAnim, forKey: "fillWipe")
        }

        // Glow behind the line — fade in after curve morph completes
        let glow = CAShapeLayer()
        glow.path = curvePath
        glow.strokeColor = NSColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 0.15).cgColor
        glow.lineWidth = 4
        glow.fillColor = nil
        glow.lineCap = .round
        glow.lineJoin = .round
        glow.opacity = animated ? 0 : 1
        curveLayer.addSublayer(glow)

        if animated {
            let glowFade = CABasicAnimation(keyPath: "opacity")
            glowFade.fromValue = 0
            glowFade.toValue = 1.0
            glowFade.duration = 0.35
            glowFade.beginTime = CACurrentMediaTime() + 0.45
            glowFade.fillMode = .forwards
            glowFade.isRemovedOnCompletion = false
            glow.add(glowFade, forKey: "glowFade")
        }

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
            snapLayer.frame = bounds
            layer?.addSublayer(snapLayer)

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
        if animated {
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.93, 1.0]
            pop.keyTimes = [0, 1]
            pop.duration = 0.5
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            curveLayer.add(pop, forKey: "chartPop")
        }
    }

    /// Decimals needed so adjacent Y-axis ticks stay distinguishable. A flat
    /// series has a tiny vertical range, and a fixed precision collapses every
    /// grid label to the same value (e.g. five "¥5.4" rows).
    private func axisFractionDigits(range: Double, steps: Int) -> Int {
        let step = range / Double(max(steps, 1))
        guard step > 0 else { return 1 }
        return min(4, max(1, Int(ceil(-log10(step)))))
    }

    /// Captures the current chart content as a bitmap for the crossfade.
    private func captureChartBitmap() -> CGImage? {
        guard let layer, let subs = layer.sublayers, !subs.isEmpty else { return nil }
        let bounds = layer.bounds
        let scale = screenScale
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

    /// Straight line segments through the given points.
    private func polylinePath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard pts.count >= 1 else { return path }
        path.move(to: pts[0])
        for i in 1..<pts.count {
            path.addLine(to: pts[i])
        }
        return path
    }

    private func makeAxisLabel(_ text: String, size: CGFloat, color: NSColor) -> CATextLayer {
        let l = CATextLayer()
        l.string = text
        l.fontSize = size
        l.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        l.foregroundColor = color.cgColor
        l.contentsScale = screenScale
        return l
    }

    private func decimalDouble(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
