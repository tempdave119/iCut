import AppKit

/// 剪贴板面板：搜索、键盘导航、复制、删除与永久保留。
/// 只负责展示与交互，数据读写全部交给 ClipboardController。
final class ClipboardPanel: NSPanel, NSWindowDelegate {
    /// Bool 表示复制后是否保持面板打开；返回值表示写回是否成功。
    var onCopy: ((ClipboardStore.ClipItem, Bool) -> Bool)?
    var onDelete: ((ClipboardStore.ClipItem) -> Void)?
    var onTogglePin: ((ClipboardStore.ClipItem) -> Void)?
    var onClearAll: (() -> Void)?
    var onClearUnpinned: (() -> Void)?
    var onPin: ((ClipboardStore.ClipItem) -> Void)?
    var onOCR: ((ClipboardStore.ClipItem) -> Void)?
    var onSave: ((ClipboardStore.ClipItem) -> Void)?
    var onHide: (() -> Void)?
    var onKeepOpenChanged: ((Bool) -> Void)?

    private let panelView = ClipboardPanelView()
    /// Esc 必须无论焦点在搜索框还是表格都能关闭；局部监视器比 responder 链可靠。
    private var escapeMonitor: Any?
    private var didInitialLayout = false
    /// 弹系统确认框时面板会失焦，不能因此自动收起。
    private var isAlertPresented = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "剪贴板"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        minSize = NSSize(width: 360, height: 300)
        delegate = self
        contentView = panelView

        _ = setFrameAutosaveName("ClipboardPanelFrame")

        panelView.onCopy = { [weak self] item, keepOpen in
            self?.onCopy?(item, keepOpen) ?? false
        }
        panelView.onDelete = { [weak self] item in self?.onDelete?(item) }
        panelView.onTogglePin = { [weak self] item in self?.onTogglePin?(item) }
        panelView.onClearAll = { [weak self] in self?.onClearAll?() }
        panelView.onClearUnpinned = { [weak self] in self?.onClearUnpinned?() }
        panelView.onHide = { [weak self] in self?.hidePanel() }
        panelView.onPin = { [weak self] item in self?.onPin?(item) }
        panelView.onOCR = { [weak self] item in self?.onOCR?(item) }
        panelView.onSave = { [weak self] item in self?.onSave?(item) }
        panelView.onKeepOpenChanged = { [weak self] enabled in
            self?.onKeepOpenChanged?(enabled)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(items: [ClipboardStore.ClipItem], storageFull: Bool, retention: TimeInterval?) {
        panelView.apply(items: items, storageFull: storageFull, retention: retention)
    }

    func syncKeepOpen(_ enabled: Bool) {
        panelView.syncKeepOpen(enabled)
    }

    func setAlertPresented(_ presented: Bool) {
        isAlertPresented = presented
    }

    func showPanel() {
        if !didInitialLayout {
            // 有保存过的位置就直接恢复，首次使用才自动定位
            if !setFrameUsingName("ClipboardPanelFrame") {
                positionOnScreen()
            }
            didInitialLayout = true
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        panelView.focusSearch()
        installEscapeMonitor()
    }

    func hidePanel() {
        removeEscapeMonitor()
        guard isVisible else { return }
        orderOut(nil)
        onHide?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 弹右键菜单时 key window 仍是面板；真正切走才收起，避免菜单一弹就消失
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isAlertPresented, !self.isKeyWindow else { return }
            self.hidePanel()
        }
    }

    /// 点标题栏关闭按钮时也走同一套清理，避免监视器残留。
    func windowWillClose(_ notification: Notification) {
        removeEscapeMonitor()
        onHide?()
    }

    /// 出现在屏幕中上部，贴近 Spotlight 的直觉，不挡住下方正在编辑的内容。
    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 140
        )
        setFrameOrigin(origin)
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == 53 else { return event }
            self.hidePanel()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }
}

final class ClipboardPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onCopy: ((ClipboardStore.ClipItem, Bool) -> Bool)?
    var onDelete: ((ClipboardStore.ClipItem) -> Void)?
    var onTogglePin: ((ClipboardStore.ClipItem) -> Void)?
    var onClearAll: (() -> Void)?
    var onClearUnpinned: (() -> Void)?
    var onPin: ((ClipboardStore.ClipItem) -> Void)?
    var onOCR: ((ClipboardStore.ClipItem) -> Void)?
    var onSave: ((ClipboardStore.ClipItem) -> Void)?
    var onHide: (() -> Void)?
    var onKeepOpenChanged: ((Bool) -> Void)?

    private static let defaultHint = "Enter 复制 · ⌥⌫ 删除 · Esc 关闭"

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: defaultHint)
    private let keepOpenSwitch = NSButton(checkboxWithTitle: "保持打开", target: nil, action: nil)
    private let bottomBar = NSView()
    private let separator = NSView()
    private let clearUnpinnedButton = NSButton(title: "清除", target: nil, action: nil)

    private var items: [ClipboardStore.ClipItem] = []
    private var filtered: [ClipboardStore.ClipItem] = []
    private var storageFull = false
    private var retention: TimeInterval?
    private var statusWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("ClipboardPanelView 不支持从 nib 加载")
    }

    // MARK: - 对外

    func apply(items: [ClipboardStore.ClipItem], storageFull: Bool, retention: TimeInterval?) {
        self.items = items
        self.storageFull = storageFull
        self.retention = retention
        bannerLabel.stringValue = storageFull ? "存储预算已被收藏占满，新内容暂不记录" : ""
        bannerLabel.isHidden = !storageFull
        reloadFiltered(selectFirst: true)
    }

    func syncKeepOpen(_ enabled: Bool) {
        keepOpenSwitch.state = enabled ? .on : .off
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    // MARK: - 布局

    private func setUpSubviews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        searchField.placeholderString = "搜索剪贴板内容"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(copyCurrent(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        bannerLabel.font = .systemFont(ofSize: 11)
        bannerLabel.textColor = .systemOrange
        bannerLabel.isHidden = true
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.stringValue = "还没有记录。复制任意文本或图片后会出现在这里。"
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        keepOpenSwitch.target = self
        keepOpenSwitch.action = #selector(keepOpenToggled)
        keepOpenSwitch.font = .systemFont(ofSize: 11)
        keepOpenSwitch.translatesAutoresizingMaskIntoConstraints = false

        clearUnpinnedButton.bezelStyle = .rounded
        clearUnpinnedButton.controlSize = .small
        clearUnpinnedButton.font = .systemFont(ofSize: 11)
        clearUnpinnedButton.target = self
        clearUnpinnedButton.action = #selector(clearUnpinnedClicked)
        clearUnpinnedButton.toolTip = "清除所有未永久保留的记录"
        clearUnpinnedButton.translatesAutoresizingMaskIntoConstraints = false

        // 底部栏单独着色：与列表明确分界，控件不会看起来压在内容上
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(bannerLabel)
        addSubview(scrollView)
        addSubview(emptyLabel)
        addSubview(bottomBar)
        bottomBar.addSubview(separator)
        bottomBar.addSubview(keepOpenSwitch)
        bottomBar.addSubview(hintLabel)
        bottomBar.addSubview(clearUnpinnedButton)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            bannerLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            bannerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bannerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: bannerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),

            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 38),

            separator.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            keepOpenSwitch.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            keepOpenSwitch.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            clearUnpinnedButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            clearUnpinnedButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: keepOpenSwitch.trailingAnchor, constant: 10),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearUnpinnedButton.leadingAnchor, constant: -10),
            hintLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
        ])
    }

    // MARK: - 数据

    private func reloadFiltered(selectFirst: Bool) {
        let needle = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            filtered = items
        } else {
            filtered = items.filter { item in
                if let text = item.text, text.lowercased().contains(needle) { return true }
                if let paths = item.filePaths, paths.contains(where: { $0.lowercased().contains(needle) }) {
                    return true
                }
                return false
            }
        }

        tableView.reloadData()
        emptyLabel.isHidden = !filtered.isEmpty
        emptyLabel.stringValue = items.isEmpty
            ? "还没有记录。复制任意文本或图片后会出现在这里。"
            : "没有匹配的记录。"

        if selectFirst, !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    private var selectedItem: ClipboardStore.ClipItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return nil }
        return filtered[row]
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ClipItemRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? ClipItemRowView
            ?? ClipItemRowView(identifier: identifier)
        let item = filtered[row]
        // 行内按钮固定「复制但不关闭」，便于连续复制多条
        view.configure(with: item, query: searchField.stringValue, retention: retention) { [weak self] in
            self?.copy(item, keepOpen: true)
        }
        return view
    }

    // MARK: - 搜索框键盘

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            copyCurrent(nil)
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                onClearAll?()
                return true
            }
            if flags.contains(.option) {
                if let item = selectedItem { onDelete?(item) }
                return true
            }
            // 无修饰键时交还给搜索框，让用户能正常删字
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            onHide?()
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        reloadFiltered(selectFirst: true)
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - 复制

    @objc private func copyCurrent(_ sender: Any?) {
        performCopyFromSelection(keepOpen: nil)
    }

    private func performCopyFromSelection(keepOpen override: Bool?) {
        guard let item = selectedItem else {
            showStatus("先选中一条记录")
            return
        }
        let shouldKeepOpen = override ?? (keepOpenSwitch.state == .on)
        copy(item, keepOpen: shouldKeepOpen)
    }

    private func copy(_ item: ClipboardStore.ClipItem, keepOpen: Bool) {
        guard let ok = onCopy?(item, keepOpen) else { return }
        showStatus(ok ? "已复制，可在前台按 ⌘V 粘贴" : "复制失败，请重试")
    }

    @objc private func keepOpenToggled() {
        onKeepOpenChanged?(keepOpenSwitch.state == .on)
    }

    @objc private func clearUnpinnedClicked() {
        onClearUnpinned?()
    }

    private func showStatus(_ text: String) {
        statusWorkItem?.cancel()
        hintLabel.stringValue = text
        let work = DispatchWorkItem { [weak self] in
            self?.hintLabel.stringValue = Self.defaultHint
        }
        statusWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: tableView.convert(point, from: self))
        guard row >= 0, row < filtered.count else { return nil }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let item = filtered[row]
        let menu = NSMenu()
        menu.addItem(menuItem(title: "复制", action: #selector(copyCurrent(_:))))
        if item.kind == .image {
            menu.addItem(menuItem(title: "贴图", action: #selector(pinCurrent)))
            menu.addItem(menuItem(title: "识别文字", action: #selector(ocrCurrent)))
            menu.addItem(menuItem(title: "保存 PNG…", action: #selector(saveCurrent)))
        }
        menu.addItem(.separator())
        let pinTitle = item.isPinned ? "取消永久保留" : "永久保留"
        menu.addItem(menuItem(title: pinTitle, action: #selector(togglePinCurrent)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "删除", action: #selector(deleteCurrent)))
        menu.addItem(menuItem(title: "清空…", action: #selector(clearAllItems)))
        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func togglePinCurrent() {
        guard let item = selectedItem else { return }
        onTogglePin?(item)
    }

    @objc private func pinCurrent() {
        guard let item = selectedItem else { return }
        onPin?(item)
    }

    @objc private func ocrCurrent() {
        guard let item = selectedItem else { return }
        onOCR?(item)
    }

    @objc private func saveCurrent() {
        guard let item = selectedItem else { return }
        onSave?(item)
    }

    @objc private func deleteCurrent() {
        guard let item = selectedItem else { return }
        onDelete?(item)
    }

    @objc private func clearAllItems() {
        onClearAll?()
    }
}

/// 单行：类型图标（图片用缩略图）、摘要、相对时间、行内复制按钮与永久保留标记。
final class ClipItemRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let pinView = NSImageView()
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)

    private var onCopy: (() -> Void)?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setUpSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("ClipItemRowView 不支持从 nib 加载")
    }

    private func setUpSubviews() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "永久保留")
        pinView.contentTintColor = .systemOrange
        pinView.isHidden = true
        pinView.translatesAutoresizingMaskIntoConstraints = false

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.toolTip = "复制到剪贴板（面板保持打开）"
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(pinView)
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 44),

            pinView.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            pinView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinView.widthAnchor.constraint(equalToConstant: 12),
            pinView.heightAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinView.leadingAnchor, constant: -8),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinView.leadingAnchor, constant: -8)
        ])
    }

    func configure(
        with item: ClipboardStore.ClipItem,
        query: String,
        retention: TimeInterval?,
        onCopy: @escaping () -> Void
    ) {
        self.onCopy = onCopy
        pinView.isHidden = !item.isPinned

        switch item.kind {
        case .text:
            iconView.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "文本")
            iconView.contentTintColor = .secondaryLabelColor
            titleLabel.attributedStringValue = Self.highlighted(Self.summary(for: item.text), query: query)
        case .image:
            if let data = item.thumbnailPNG, let image = NSImage(data: data) {
                iconView.image = image
                iconView.contentTintColor = nil
            } else {
                iconView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "图片")
                iconView.contentTintColor = .secondaryLabelColor
            }
            titleLabel.stringValue = "图片"
        case .fileURLs:
            iconView.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "文件")
            iconView.contentTintColor = .secondaryLabelColor
            titleLabel.attributedStringValue = Self.highlighted(
                Self.fileSummary(for: item.filePaths ?? []),
                query: query
            )
        }

        var parts = [Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date())]
        if item.isFromCapture == true { parts.append("iCut 截图") }
        if item.isTruncated { parts.append("已截断") }
        if item.kind == .fileURLs, let paths = item.filePaths,
           paths.contains(where: { !FileManager.default.fileExists(atPath: $0) }) {
            parts.append("文件已不存在")
        }
        parts.append(ClipboardExpiry.text(
            createdAt: item.createdAt,
            isPinned: item.isPinned,
            retention: retention
        ))
        detailLabel.stringValue = parts.joined(separator: " · ")
    }

    /// 搜索词在标题里高亮，长文本在摘要截断范围内命中时也能看到位置。
    private static func highlighted(_ text: String, query: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]
        )
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }

        let lowerText = text.lowercased()
        let lowerNeedle = needle.lowercased()
        var searchStart = lowerText.startIndex
        while searchStart < lowerText.endIndex,
              let range = lowerText.range(of: lowerNeedle, range: searchStart..<lowerText.endIndex) {
            attributed.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.35),
                range: NSRange(range, in: text)
            )
            searchStart = range.upperBound
        }
        return attributed
    }

    @objc private func copyClicked() {
        onCopy?()
    }

    private static func summary(for text: String?) -> String {
        guard let text else { return "（空文本）" }
        let singleLine = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(singleLine.prefix(120))
    }

    private static func fileSummary(for paths: [String]) -> String {
        guard let first = paths.first else { return "文件" }
        let name = URL(fileURLWithPath: first).lastPathComponent
        return paths.count > 1 ? "\(name) 等 \(paths.count) 个文件" : name
    }
}
