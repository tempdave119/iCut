import AppKit

/// 剪贴板历史设置页：与截图设置分页，避免两套配置互相影响。
final class ClipboardSettingsView: NSView {
    var onClipboardChanged: ((ClipboardSettings) -> Void)?
    var onClearClipboard: (() -> Void)?
    var onRequestHotKeyEdit: (() -> Void)?

    var hotKeyText = "" {
        didSet { hotKeyValue.stringValue = hotKeyText }
    }

    private var settings = ClipboardSettings.load()

    private let clipboardSwitch = NSButton(
        checkboxWithTitle: "记录剪贴板内容",
        target: nil,
        action: nil
    )
    private let recordImagesSwitch = NSButton(
        checkboxWithTitle: "记录图片（含截图历史）",
        target: nil,
        action: nil
    )
    private let keepOpenSwitch = NSButton(
        checkboxWithTitle: "复制后保持面板打开",
        target: nil,
        action: nil
    )
    private let hotKeyValue = NSTextField(labelWithString: "")
    private let maxEntriesPopup = NSPopUpButton()
    private let imageBudgetPopup = NSPopUpButton()
    private let retentionPopup = NSPopUpButton()
    private let clearButton = NSButton(title: "清空记录…", target: nil, action: nil)
    private let encryptionLabel = NSTextField(labelWithString: "已加密 · AES-256-GCM")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hotKeyText = settings.hotKey.displayText
        setUpSubviews()
        applySettings()
    }

    required init?(coder: NSCoder) {
        fatalError("ClipboardSettingsView 不支持从 nib 加载")
    }

    // MARK: - 布局

    private func setUpSubviews() {
        let intro = NSTextField(
            wrappingLabelWithString: "记录本机剪贴板内容，默认关闭；开启后只在本机加密存储。iCut 未运行时不会记录。"
        )
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor

        clipboardSwitch.target = self
        clipboardSwitch.action = #selector(clipboardToggled)
        recordImagesSwitch.target = self
        recordImagesSwitch.action = #selector(recordImagesToggled)
        keepOpenSwitch.target = self
        keepOpenSwitch.action = #selector(keepOpenToggled)

        hotKeyValue.font = .systemFont(ofSize: 13, weight: .medium)
        let editButton = NSButton(title: "修改…", target: self, action: #selector(editHotKey))
        editButton.bezelStyle = .rounded
        let hotKeyRow = horizontalRow([captionLabel("快捷键"), hotKeyValue, editButton])

        maxEntriesPopup.target = self
        maxEntriesPopup.action = #selector(limitsChanged)
        imageBudgetPopup.target = self
        imageBudgetPopup.action = #selector(limitsChanged)
        retentionPopup.target = self
        retentionPopup.action = #selector(limitsChanged)

        let limitsRow = horizontalRow([
            captionLabel("条数"),
            maxEntriesPopup,
            captionLabel("图片"),
            imageBudgetPopup
        ])
        let retentionRow = horizontalRow([captionLabel("保留"), retentionPopup, encryptionLabel])

        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        clearButton.bezelStyle = .rounded

        encryptionLabel.font = .systemFont(ofSize: 11)
        encryptionLabel.textColor = .secondaryLabelColor

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = "记录范围：文本、图片与文件路径。文件只记引用，原文件移动或删除后该条会失效；无法识别来源应用，密码管理器若未标记也可能被记录。"

        let root = NSStackView(views: [
            intro,
            clipboardSwitch,
            hotKeyRow,
            recordImagesSwitch,
            keepOpenSwitch,
            limitsRow,
            retentionRow,
            clearButton,
            hintLabel
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        // 固定窗口高度下内容可能超出，外层滚动避免底部说明被裁剪
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let document = NSView()
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
            intro.widthAnchor.constraint(equalToConstant: 460),
            hintLabel.widthAnchor.constraint(equalToConstant: 460),
            maxEntriesPopup.widthAnchor.constraint(equalToConstant: 96),
            imageBudgetPopup.widthAnchor.constraint(equalToConstant: 96),
            retentionPopup.widthAnchor.constraint(equalToConstant: 96)
        ])
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
        label.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return label
    }

    // MARK: - 状态

    /// 面板内勾选「保持打开」会写回同一份配置，打开设置页时重新读盘保持一致。
    func reloadFromDisk() {
        settings = ClipboardSettings.load()
        hotKeyText = settings.hotKey.displayText
        applySettings()
    }

    private func applySettings() {
        clipboardSwitch.state = settings.enabled ? .on : .off
        recordImagesSwitch.state = settings.recordImages ? .on : .off
        keepOpenSwitch.state = settings.keepPanelOpen ? .on : .off
        hotKeyValue.stringValue = hotKeyText.isEmpty ? settings.hotKey.displayText : hotKeyText

        maxEntriesPopup.removeAllItems()
        maxEntriesPopup.addItems(withTitles: ClipboardSettings.maxEntriesChoices.map { "\($0) 条" })
        maxEntriesPopup.selectItem(
            at: ClipboardSettings.maxEntriesChoices.firstIndex(of: settings.maxEntries) ?? 1
        )

        imageBudgetPopup.removeAllItems()
        imageBudgetPopup.addItems(withTitles: ClipboardSettings.imageBudgetChoices.map { "\($0) MB" })
        imageBudgetPopup.selectItem(
            at: ClipboardSettings.imageBudgetChoices.firstIndex(of: settings.imageBudgetMB) ?? 1
        )

        retentionPopup.removeAllItems()
        retentionPopup.addItems(withTitles: ClipboardSettings.retentionChoices.map { $0 == 0 ? "永久" : "\($0) 天" })
        retentionPopup.selectItem(
            at: ClipboardSettings.retentionChoices.firstIndex(of: settings.retentionDays) ?? 1
        )

        let enabled = settings.enabled
        recordImagesSwitch.isEnabled = enabled
        keepOpenSwitch.isEnabled = enabled
        maxEntriesPopup.isEnabled = enabled
        imageBudgetPopup.isEnabled = enabled
        retentionPopup.isEnabled = enabled
        clearButton.isEnabled = enabled
        encryptionLabel.textColor = enabled ? .secondaryLabelColor : .disabledControlTextColor
    }

    private func persist() {
        // 热键由录制流程单独保存，这里不写回，避免用旧值覆盖新组合
        ClipboardSettings.save(settings)
        applySettings()
        onClipboardChanged?(settings)
        NSLog(
            "iCut: 剪贴板历史设置已更新（开启=\(settings.enabled)，图片=\(settings.recordImages)）"
        )
    }

    // MARK: - 动作

    @objc private func clipboardToggled() {
        let wantsEnabled = clipboardSwitch.state == .on
        if wantsEnabled, !confirmEnable() {
            clipboardSwitch.state = .off
            return
        }
        settings.enabled = wantsEnabled
        persist()
    }

    @objc private func recordImagesToggled() {
        settings.recordImages = recordImagesSwitch.state == .on
        persist()
    }

    @objc private func keepOpenToggled() {
        settings.keepPanelOpen = keepOpenSwitch.state == .on
        persist()
    }

    @objc private func limitsChanged() {
        let entriesIndex = maxEntriesPopup.indexOfSelectedItem
        if ClipboardSettings.maxEntriesChoices.indices.contains(entriesIndex) {
            settings.maxEntries = ClipboardSettings.maxEntriesChoices[entriesIndex]
        }
        let budgetIndex = imageBudgetPopup.indexOfSelectedItem
        if ClipboardSettings.imageBudgetChoices.indices.contains(budgetIndex) {
            settings.imageBudgetMB = ClipboardSettings.imageBudgetChoices[budgetIndex]
        }
        let retentionIndex = retentionPopup.indexOfSelectedItem
        if ClipboardSettings.retentionChoices.indices.contains(retentionIndex) {
            settings.retentionDays = ClipboardSettings.retentionChoices[retentionIndex]
        }
        persist()
    }

    @objc private func clearHistory() {
        onClearClipboard?()
    }

    @objc private func editHotKey() {
        onRequestHotKeyEdit?()
    }

    private func confirmEnable() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "开启剪贴板记录？"
        alert.informativeText = "iCut 会记录复制过的文本、图片与文件路径，只存本机并使用 AES-256-GCM 加密。iCut 未运行期间的复制不会记录；无法识别来源应用，密码管理器若未打标记也可能被记录。可随时点「清空历史」删除。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "开启")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
