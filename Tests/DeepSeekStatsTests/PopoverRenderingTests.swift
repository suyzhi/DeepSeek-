import AppKit
import Foundation
import Testing
@testable import DeepSeekStats

/// Layout/rendering checks for the popover.
///
/// Set `DSH_SNAPSHOT_DIR` to a writable directory to also dump PNGs of the
/// rendered popover for manual inspection.
@MainActor
struct PopoverRenderingTests {
    @Test func testIntervalPillsAreWideEnoughForTheirLabels() {
        let controller = makeController(hasChange: true)
        #expect(controller.intervalButtons.count == ChartInterval.supported.count)

        // A bordered bezel would stack a second rounded background over the
        // layer-drawn pill and clip the labels.
        #expect(!controller.topUpButton.isBordered)
        #expect(controller.intervalButtons.allSatisfy { !$0.isBordered })

        let probe = NSRect(x: 0, y: 0, width: 1_000, height: 100)
        for (button, interval) in zip(controller.intervalButtons, ChartInterval.supported) {
            let needed = button.cell!.cellSize(forBounds: probe).width
            let available = button.bounds.width
            #expect(
                available >= needed,
                "区间按钮「\(interval.label)」文字会被裁切：可用 \(available)pt，需要 \(needed)pt"
            )
        }
    }

    @Test func testRendersPopoverSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["DSH_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: directory)

        try writeSnapshot(
            makeController(hasChange: true).view,
            to: base.appendingPathComponent("popover-expanded.png"),
            settling: 0.2
        )
        try writeSnapshot(
            makeController(hasChange: false).view,
            to: base.appendingPathComponent("popover-compact.png"),
            settling: 0.7
        )
    }

    private func makeController(hasChange: Bool) -> PopoverViewController {
        let controller = PopoverViewController()
        controller.animatesChart = false
        // Mirrors AppDelegate: the popover resizes itself when compact mode toggles.
        controller.onContentSizeChange = { [weak controller] size in
            controller?.view.setFrameSize(size)
        }
        _ = controller.view
        let now = Date()
        // hasChange: 5.42 -> 10.57 inside the window, so the "充值" row stays visible
        // and the popover stays expanded. Otherwise nothing moves and it compacts.
        let startAmount = Decimal(string: "5.42")!
        let endAmount = Decimal(string: "10.57")!
        let samples = (0..<40).map { index in
            BalanceSample(
                timestamp: now.addingTimeInterval(-Double(40 - index) * 3_600),
                amount: hasChange && index >= 25 ? endAmount : startAmount,
                currency: "CNY"
            )
        }
        controller.render(.fresh(
            snapshot: BalanceSnapshot(
                amount: hasChange ? endAmount : startAmount,
                currency: "CNY",
                fetchedAt: now.addingTimeInterval(-600)
            ),
            history: samples
        ))
        controller.view.layoutSubtreeIfNeeded()
        controller.view.display()
        return controller
    }

    private func writeSnapshot(_ view: NSView, to url: URL, settling: TimeInterval) throws {
        // A layer-backed view only commits its layer tree once it belongs to an
        // ordered-in window, so park it far offscreen while it renders.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: view.bounds.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settling))
        defer { window.orderOut(nil) }

        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Could not create bitmap context")
            return
        }

        // Opaque backdrop: the popover's blur material renders nothing offscreen.
        context.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        view.layer?.render(in: context)

        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            Issue.record("Could not encode snapshot")
            return
        }
        try data.write(to: url)
    }
}
