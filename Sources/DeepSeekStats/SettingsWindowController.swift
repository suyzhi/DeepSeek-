import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    private let keyStore: any APIKeyStoreProtocol
    private let keyProvider: APIKeyProvider
    private let apiClient: any DeepSeekAPIClientProtocol
    private let historyStore: any BalanceHistoryStoreProtocol
    private let settings: AppSettings
    private let loginItemManager: LoginItemManager

    private let keyField = NSSecureTextField(frame: .zero)
    private let keyStatusLabel = NSTextField(labelWithString: "")
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时自动启动", target: nil, action: nil)
    private let saveButton = NSButton(title: "验证并保存", target: nil, action: nil)

    var onAPIKeyChanged: (() -> Void)?
    var onRefreshIntervalChanged: (() -> Void)?
    var onHistoryCleared: (() -> Void)?

    init(
        keyStore: any APIKeyStoreProtocol,
        keyProvider: APIKeyProvider,
        apiClient: any DeepSeekAPIClientProtocol,
        historyStore: any BalanceHistoryStoreProtocol,
        settings: AppSettings,
        loginItemManager: LoginItemManager
    ) {
        self.keyStore = keyStore
        self.keyProvider = keyProvider
        self.apiClient = apiClient
        self.historyStore = historyStore
        self.settings = settings
        self.loginItemManager = loginItemManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeekStats 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        reloadValues()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = label("API Key", size: 13, weight: .semibold)
        title.frame = NSRect(x: 24, y: 252, width: 100, height: 20)
        content.addSubview(title)

        keyField.frame = NSRect(x: 24, y: 216, width: 276, height: 26)
        keyField.placeholderString = "sk-..."
        content.addSubview(keyField)

        saveButton.frame = NSRect(x: 308, y: 214, width: 108, height: 30)
        saveButton.target = self
        saveButton.action = #selector(saveKey)
        content.addSubview(saveButton)

        let deleteButton = NSButton(title: "删除 Key", target: self, action: #selector(deleteKey))
        deleteButton.frame = NSRect(x: 308, y: 181, width: 108, height: 28)
        content.addSubview(deleteButton)

        keyStatusLabel.frame = NSRect(x: 24, y: 184, width: 276, height: 20)
        keyStatusLabel.textColor = .secondaryLabelColor
        keyStatusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(keyStatusLabel)

        let separator = NSBox(frame: NSRect(x: 24, y: 166, width: 392, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        let refreshLabel = label("自动刷新", size: 13, weight: .semibold)
        refreshLabel.frame = NSRect(x: 24, y: 130, width: 100, height: 22)
        content.addSubview(refreshLabel)

        intervalPopup.addItems(withTitles: AppSettings.supportedRefreshIntervals.map { "\($0) 分钟" })
        intervalPopup.frame = NSRect(x: 130, y: 126, width: 120, height: 28)
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        content.addSubview(intervalPopup)

        loginCheckbox.frame = NSRect(x: 24, y: 88, width: 180, height: 22)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginItemChanged)
        content.addSubview(loginCheckbox)

        let clearButton = NSButton(title: "清除余额历史…", target: self, action: #selector(clearHistory))
        clearButton.frame = NSRect(x: 24, y: 40, width: 130, height: 30)
        content.addSubview(clearButton)

        let retention = label("历史默认保留 30 天，API Key 保存在系统钥匙串。", size: 11, weight: .regular)
        retention.textColor = .secondaryLabelColor
        retention.frame = NSRect(x: 170, y: 44, width: 246, height: 20)
        content.addSubview(retention)
    }

    private func reloadValues() {
        if let key = try? keyStore.read(), !key.isEmpty {
            keyField.stringValue = key
            keyStatusLabel.stringValue = "已保存在系统钥匙串"
        } else {
            keyField.stringValue = ""
            keyStatusLabel.stringValue = "正在检查旧配置…"
            Task { [weak self] in
                guard let self else { return }
                let source = await keyProvider.source()
                switch source {
                case .environment: self.keyStatusLabel.stringValue = "当前使用环境变量（仅开发用途）"
                case .legacyFile: self.keyStatusLabel.stringValue = "检测到 ~/.hermes/.env，刷新时将导入钥匙串"
                case .missing: self.keyStatusLabel.stringValue = "尚未配置 API Key"
                case .keychain: self.keyStatusLabel.stringValue = "已保存在系统钥匙串"
                }
            }
        }
        let current = settings.refreshIntervalMinutes
        intervalPopup.selectItem(at: AppSettings.supportedRefreshIntervals.firstIndex(of: current) ?? 1)
        loginCheckbox.state = loginItemManager.isEnabled ? .on : .off
    }

    @objc private func saveKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keyStatusLabel.stringValue = "请输入 API Key"
            keyStatusLabel.textColor = .systemRed
            return
        }
        saveButton.isEnabled = false
        keyStatusLabel.textColor = .secondaryLabelColor
        keyStatusLabel.stringValue = "正在验证…"

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await apiClient.fetchBalance(apiKey: key)
                try keyStore.save(key)
                keyStatusLabel.textColor = .systemGreen
                keyStatusLabel.stringValue = "验证成功，已保存到钥匙串"
                onAPIKeyChanged?()
            } catch {
                keyStatusLabel.textColor = .systemRed
                keyStatusLabel.stringValue = error.localizedDescription
            }
            saveButton.isEnabled = true
        }
    }

    @objc private func deleteKey() {
        let alert = NSAlert()
        alert.messageText = "删除 API Key？"
        alert.informativeText = "删除后应用将无法刷新余额，除非仍配置了环境变量或旧 .env 文件。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try keyStore.delete()
            keyField.stringValue = ""
            keyStatusLabel.textColor = .secondaryLabelColor
            keyStatusLabel.stringValue = "钥匙串中的 API Key 已删除"
            onAPIKeyChanged?()
        } catch {
            showError(error)
        }
    }

    @objc private func intervalChanged() {
        let index = intervalPopup.indexOfSelectedItem
        guard AppSettings.supportedRefreshIntervals.indices.contains(index) else { return }
        settings.refreshIntervalMinutes = AppSettings.supportedRefreshIntervals[index]
        onRefreshIntervalChanged?()
    }

    @objc private func loginItemChanged() {
        let desired = loginCheckbox.state == .on
        do {
            try loginItemManager.setEnabled(desired)
        } catch {
            loginCheckbox.state = loginItemManager.isEnabled ? .on : .off
            showError(error)
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清除余额历史？"
        alert.informativeText = "该操作无法撤销，当前余额会在下次刷新时重新记录。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await historyStore.clear()
                onHistoryCleared?()
            } catch {
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        return label
    }
}
