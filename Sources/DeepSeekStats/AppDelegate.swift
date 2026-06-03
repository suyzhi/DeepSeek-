import AppKit
import Foundation

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverVC: PopoverViewController!
    private var timer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force-create a fresh status item (handles Cmd+drag removal)
        installStatusItem()
        
        // Create popover with frosted glass
        popoverVC = PopoverViewController()
        popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true
        
        // Start periodic refresh (every 5 minutes)
        refreshData()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshData()
            }
        }
    }
    
    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshData()
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    
    @objc func refreshData() {
        Task { @MainActor in
            popoverVC.showLoading()
            do {
                let balances = try await DeepSeekAPIClient.shared.fetchBalance()
                if let b = balances.balanceInfos.first {
                    let balanceValue = Double(b.totalBalance) ?? 0
                    // Save to local history
                    BalanceHistoryManager.shared.addPoint(balance: balanceValue, currency: b.currency)
                }
                let history = BalanceHistoryManager.shared.load()
                popoverVC.updateBalance(balances.balanceInfos.first, history: history)
            } catch {
                let history = BalanceHistoryManager.shared.load()
                if !history.isEmpty {
                    // Still show chart with existing history
                    popoverVC.updateBalance(nil, history: history)
                } else {
                    popoverVC.showBalanceError(error.localizedDescription)
                }
            }
        }
    }
    
    // Create or recreate the status item (handles Cmd+drag removal)
    private func installStatusItem() {
        // Remove any existing item first to ensure fresh creation
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = createStatusBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    // Create a simple status bar icon
    private func createStatusBarIcon() -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        
        // Draw "DS" text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.white
        ]
        let text = "DS"
        text.draw(at: NSPoint(x: 2, y: 1), withAttributes: attributes)
        
        // Draw a small green dot (status indicator)
        let dotRect = NSRect(x: 15, y: 4, width: 4, height: 4)
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
