import AppKit

/// 滚动区的文档视图必须翻转坐标系：未翻转时内容比可视区矮会贴底，比可视区高则初始停在底部
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// 统一设置窗口：截图与剪贴板历史分页，两套配置互不影响。
final class SettingsWindow: NSWindow, NSWindowDelegate {
    private let captureView = SettingsContentView()
    private let clipboardView = ClipboardSettingsView()

    /// 快捷键录制涉及热键重注册与配置落盘，交给 AppDelegate 处理
    var onRequestHotKeyEdit: (() -> Void)?
    var onRequestClipboardHotKeyEdit: (() -> Void)?
    var onClipboardChanged: ((ClipboardSettings) -> Void)?
    var onClearClipboard: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "iCut 设置"
        isReleasedWhenClosed = false
        delegate = self
        center()

        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder

        let captureTab = NSTabViewItem(identifier: "capture")
        captureTab.label = "截图"
        captureTab.view = captureView
        tabView.addTabViewItem(captureTab)

        let clipboardTab = NSTabViewItem(identifier: "clipboard")
        clipboardTab.label = "剪贴板"
        clipboardTab.view = clipboardView
        tabView.addTabViewItem(clipboardTab)

        contentView = tabView

        captureView.onRequestHotKeyEdit = { [weak self] in self?.onRequestHotKeyEdit?() }
        clipboardView.onRequestHotKeyEdit = { [weak self] in self?.onRequestClipboardHotKeyEdit?() }
        clipboardView.onClipboardChanged = { [weak self] settings in self?.onClipboardChanged?(settings) }
        clipboardView.onClearClipboard = { [weak self] in self?.onClearClipboard?() }
    }

    func refreshHotKey(_ config: HotKeyConfig) {
        captureView.hotKeyText = config.displayText
    }

    func refreshClipboardHotKey(_ config: HotKeyConfig) {
        clipboardView.hotKeyText = config.displayText
    }

    /// 面板内也能改「保持打开」，打开设置窗口时重新读盘避免显示旧值。
    func refreshClipboardSettings() {
        clipboardView.reloadFromDisk()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

final class SettingsContentView: NSView, NSTextFieldDelegate {
    var onRequestHotKeyEdit: (() -> Void)?

    var hotKeyText = "" {
        didSet { hotKeyValue.stringValue = hotKeyText }
    }

    private var settings = AutoSaveSettings.load()

    private let hotKeyValue = NSTextField(labelWithString: "")
    private let toolbarControl = NSSegmentedControl(
        labels: ToolbarPosition.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let autoSaveSwitch = NSButton(
        checkboxWithTitle: "确认截图后自动保存 PNG",
        target: nil,
        action: nil
    )
    private let launchAtLoginSwitch = NSButton(
        checkboxWithTitle: "登录时自动打开 iCut",
        target: nil,
        action: nil
    )
    private let launchAtLoginHint = NSTextField(wrappingLabelWithString: "")
    private let loginItemsButton = NSButton(title: "打开登录项设置", target: nil, action: nil)
    private let directoryValue = NSTextField(labelWithString: "")
    private let chooseDirectoryButton = NSButton(title: "选择…", target: nil, action: nil)
    private let templateField = NSTextField(string: "")
    private let previewLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpSubviews()
        applyCurrentSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsContentView 不支持从 nib 加载")
    }

    // MARK: - 布局

    private func setUpSubviews() {
        hotKeyValue.font = .systemFont(ofSize: 13, weight: .medium)

        let editButton = NSButton(title: "修改…", target: self, action: #selector(editHotKey))
        let hotKeyRow = horizontalRow([hotKeyValue, editButton])

        toolbarControl.target = self
        toolbarControl.action = #selector(toolbarChanged)

        autoSaveSwitch.target = self
        autoSaveSwitch.action = #selector(autoSaveToggled)

        chooseDirectoryButton.target = self
        chooseDirectoryButton.action = #selector(chooseDirectory)

        directoryValue.lineBreakMode = .byTruncatingMiddle
        directoryValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let directoryRow = horizontalRow([
            captionLabel("目录"),
            directoryValue,
            chooseDirectoryButton
        ])

        templateField.delegate = self
        templateField.placeholderString = FileNameTemplate.defaultTemplate
        let extensionLabel = captionLabel(".png")
        let templateRow = horizontalRow([
            captionLabel("命名"),
            templateField,
            extensionLabel
        ])

        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        let hintLabel = NSTextField(wrappingLabelWithString: "占位符：{timestamp} 时间戳（yyMMddHHmmss）、{date} 日期、{time} 时间、{datetime} 日期时间、{seq} 序号；扩展名固定 .png。选桌面 / 文稿 / 下载目录时，系统会弹出一次文件夹授权。")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginToggled)
        launchAtLoginHint.font = .systemFont(ofSize: 11)
        launchAtLoginHint.textColor = .secondaryLabelColor
        loginItemsButton.target = self
        loginItemsButton.action = #selector(openLoginItemsSettings)
        loginItemsButton.bezelStyle = .rounded
        loginItemsButton.isEnabled = false

        let aboutLabel = NSTextField(labelWithString: "iCut \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")")
        aboutLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let privacyLabel = NSTextField(wrappingLabelWithString: "所有处理均在本机完成：不联网、不上传截图或剪贴板内容，也不采集使用数据；剪贴板历史默认关闭且加密存储。")
        privacyLabel.font = .systemFont(ofSize: 11)
        privacyLabel.textColor = .secondaryLabelColor

        let root = NSStackView(views: [
            makeSection(title: "快捷键", rows: [hotKeyRow]),
            makeSection(title: "工具栏位置", rows: [toolbarControl]),
            makeSection(title: "自动保存", rows: [
                autoSaveSwitch,
                directoryRow,
                templateRow,
                previewLabel,
                hintLabel
            ]),
            makeSection(title: "启动", rows: [
                launchAtLoginSwitch,
                launchAtLoginHint,
                loginItemsButton
            ]),
            makeSection(title: "关于", rows: [aboutLabel, privacyLabel])
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false

        // 固定窗口高度下内容可能超出，外层滚动避免底部「关于」被裁剪
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        document.addSubview(root)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            root.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            root.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22),
            directoryValue.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            templateField.widthAnchor.constraint(equalToConstant: 240),
            // 自动换行的标签需要显式宽度，否则会按单行宽度撑出窗口
            hintLabel.widthAnchor.constraint(equalToConstant: 460),
            launchAtLoginHint.widthAnchor.constraint(equalToConstant: 460),
            privacyLabel.widthAnchor.constraint(equalToConstant: 460)
        ])
    }

    private func makeSection(title: String, rows: [NSView]) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let section = NSStackView(views: [titleLabel] + rows)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    private func horizontalRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return label
    }

    // MARK: - 初始化与状态

    private func applyCurrentSettings() {
        let position = ToolbarSettings.load()
        toolbarControl.selectedSegment = ToolbarPosition.allCases.firstIndex(of: position) ?? 0

        autoSaveSwitch.state = settings.enabled ? .on : .off
        directoryValue.stringValue = settings.directoryPath
        templateField.stringValue = settings.nameTemplate
        updatePreview()
        applyAutoSaveState()
        refreshLaunchAtLogin()
    }

    /// 关闭时把依赖配置的控件置灰，避免看起来能改但其实不生效
    private func applyAutoSaveState() {
        directoryValue.textColor = settings.enabled ? .labelColor : .disabledControlTextColor
        chooseDirectoryButton.isEnabled = settings.enabled
        templateField.isEnabled = settings.enabled
        previewLabel.textColor = settings.enabled ? .secondaryLabelColor : .disabledControlTextColor
    }

    private func updatePreview() {
        let name = FileNameTemplate.render(template: templateField.stringValue)
        previewLabel.stringValue = "示例：\(name).png"
    }

    private func persistAutoSave() {
        settings.nameTemplate = templateField.stringValue
        AutoSaveSettings.save(settings)
    }

    // MARK: - 动作

    @objc private func editHotKey() {
        onRequestHotKeyEdit?()
    }

    @objc private func toolbarChanged() {
        let index = toolbarControl.selectedSegment
        guard ToolbarPosition.allCases.indices.contains(index) else { return }
        let position = ToolbarPosition.allCases[index]
        ToolbarSettings.save(position)
        NSLog("iCut: 工具栏位置 = \(position.displayName)")
    }

    @objc private func autoSaveToggled() {
        settings.enabled = autoSaveSwitch.state == .on
        AutoSaveSettings.save(settings)
        applyAutoSaveState()
        NSLog("iCut: 自动保存 = \(settings.enabled ? "开启" : "关闭")")
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.directoryURL
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.directoryPath = url.path
        AutoSaveSettings.save(settings)
        directoryValue.stringValue = settings.directoryPath
        NSLog("iCut: 自动保存目录 = \(settings.directoryPath)")
    }

    @objc private func launchAtLoginToggled() {
        let wantsEnabled = launchAtLoginSwitch.state == .on
        do {
            try LaunchAtLogin.setEnabled(wantsEnabled)
            NSLog("iCut: 开机自启 = \(wantsEnabled ? "开启" : "关闭")")
            refreshLaunchAtLogin()
        } catch {
            NSLog("iCut: 开机自启\(wantsEnabled ? "开启" : "关闭")失败 — \(error.localizedDescription)")
            refreshLaunchAtLogin()
            // 失败原因盖在状态文案上，用户下次打开面板会看到真实状态
            launchAtLoginHint.stringValue = "设置失败：\(error.localizedDescription)"
        }
    }

    @objc private func openLoginItemsSettings() {
        LaunchAtLogin.openLoginItemsSettings()
    }

    private func refreshLaunchAtLogin() {
        let state = LaunchAtLogin.status
        switch state {
        case .enabled:
            launchAtLoginSwitch.state = .on
            launchAtLoginHint.stringValue = "已登记为登录项，登录系统后会自动打开。"
        case .requiresApproval:
            launchAtLoginSwitch.state = .on
            launchAtLoginHint.stringValue = "已登记，但需要在「系统设置 → 通用 → 登录项」中允许 iCut。"
        case .disabled:
            launchAtLoginSwitch.state = .off
            launchAtLoginHint.stringValue = "默认关闭；开启后登录系统时自动打开 iCut。"
        }
        loginItemsButton.isEnabled = (state == .requiresApproval)
    }

    func controlTextDidChange(_ obj: Notification) {
        updatePreview()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        persistAutoSave()
        // 空模板会被回落成默认值，回填让界面与真实配置一致
        templateField.stringValue = AutoSaveSettings.load().nameTemplate
        updatePreview()
    }
}
