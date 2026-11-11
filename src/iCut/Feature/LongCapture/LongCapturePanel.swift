import AppKit

/// 控制条上的按钮：窗口不是 key 时第一次点击也要直接生效，
/// 否则点击只会激活面板，表现为「点完成没反应」。
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 长截图时的悬浮控制条：显示已拼接高度，提供完成 / 取消；可拖动避开采集区域。
final class LongCapturePanel: NSPanel {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        // HUD 材质在浅色系统下仍是深色底，固定用深色外观让文字保持白字
        appearance = NSAppearance(named: .vibrantDark)
        setUpContent()
    }

    /// 面板不抢浏览器焦点：用户还要继续滚动页面，键盘事件留在页面上。
    /// 因此没有 Esc / 回车处理，结束会话只用面板上的「完成」「取消」按钮。
    func update(status: String, hint: String) {
        statusLabel.stringValue = status
        hintLabel.stringValue = hint
    }

    /// 优先放在选区上方：点完工具栏后鼠标就在选区下方，
    /// 面板放上去可以避免滚动时鼠标正好落在面板上而“滚不动”。
    func place(near selection: CGRect, in visibleFrame: CGRect) {
        let size = frame.size
        var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.maxY + 14)
        if origin.y + size.height > visibleFrame.maxY - 8 {
            origin.y = selection.minY - size.height - 14
        }
        origin.x = min(max(visibleFrame.minX + 8, origin.x), visibleFrame.maxX - size.width - 8)
        origin.y = min(max(visibleFrame.minY + 8, origin.y), visibleFrame.maxY - size.height - 8)
        setFrameOrigin(origin)
    }

    private func setUpContent() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        contentView = effect

        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.maximumNumberOfLines = 2
        hintLabel.lineBreakMode = .byWordWrapping

        let cancelButton = FirstMouseButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        let finishButton = FirstMouseButton(title: "完成", target: self, action: #selector(finishTapped))
        finishButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancelButton, finishButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let text = NSStackView(views: [statusLabel, hintLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4

        let row = NSStackView(views: [text, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            text.widthAnchor.constraint(equalToConstant: 250)
        ])
    }

    @objc private func finishTapped() {
        onFinish?()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
