import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum IndicatorState {
        case loading
        case fresh
        case stale
        case failed

        var color: NSColor {
            switch self {
            case .loading: .systemGray
            case .fresh: .systemGreen
            case .stale: .systemYellow
            case .failed: .systemRed
            }
        }
    }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverVC: PopoverViewController!
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var settingsWindowController: SettingsWindowController?

    private let apiClient = DeepSeekAPIClient()
    private let keyStore = KeychainAPIKeyStore()
    private let historyStore = BalanceHistoryStore()
    private let settings = AppSettings()
    private let loginItemManager = LoginItemManager()
    private lazy var keyProvider = APIKeyProvider(keyStore: keyStore)
    private lazy var coordinator = RefreshCoordinator(
        apiClient: apiClient,
        historyStore: historyStore,
        keyProvider: keyProvider
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        popoverVC = PopoverViewController()
        popoverVC.onRefresh = { [weak self] in self?.coordinator.refresh(reason: .manual) }
        popoverVC.onOpenSettings = { [weak self] in self?.openSettings() }

        popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true
        popoverVC.onContentSizeChange = { [weak self] size in
            self?.popover.contentSize = size
        }

        coordinator.onStateChange = { [weak self] state in
            self?.popoverVC.render(state)
            self?.updateStatusItem(for: state)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.coordinator.refresh(reason: .timer)
            }
        }
        scheduleTimer()
        coordinator.refresh(reason: .launch)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            coordinator.refresh(reason: .popover)
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let loginItem = menu.addItem(
            withTitle: "登录时启动",
            action: #selector(toggleLoginItemFromMenu),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = loginItemManager.isEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 DeepSeekStats", action: #selector(quit), keyEquivalent: "q").target = self

        let location = NSPoint(x: 0, y: button.bounds.height + 2)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func refreshFromMenu() {
        coordinator.refresh(reason: .manual)
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    @objc private func toggleLoginItemFromMenu() {
        do {
            try loginItemManager.setEnabled(!loginItemManager.isEnabled)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(
                keyStore: keyStore,
                keyProvider: keyProvider,
                apiClient: apiClient,
                historyStore: historyStore,
                settings: settings,
                loginItemManager: loginItemManager
            )
            controller.onAPIKeyChanged = { [weak self] in
                self?.coordinator.cancelAndRefresh(reason: .settingsChanged)
            }
            controller.onRefreshIntervalChanged = { [weak self] in self?.scheduleTimer() }
            controller.onHistoryCleared = { [weak self] in
                self?.coordinator.cancelAndRefresh(reason: .settingsChanged)
            }
            settingsWindowController = controller
        }
        settingsWindowController?.present()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let seconds = TimeInterval(settings.refreshIntervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.coordinator.refresh(reason: .timer)
            }
        }
    }

    private func installStatusItem() {
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = createStatusBarIcon(indicator: .loading)
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func updateStatusItem(for state: BalanceViewState) {
        let indicator: IndicatorState
        switch state {
        case .loading: indicator = .loading
        case .fresh: indicator = .fresh
        case .stale(_, _, let error):
            indicator = error == .missingAPIKey ? .failed : .stale
        case .failed: indicator = .failed
        }
        statusItem.button?.image = createStatusBarIcon(indicator: indicator)
    }

    private func createStatusBarIcon(indicator: IndicatorState) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]
        "DS".draw(at: NSPoint(x: 1, y: 1), withAttributes: attributes)
        indicator.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 15, y: 4, width: 4, height: 4)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
