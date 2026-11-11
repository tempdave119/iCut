import AppKit

/// 长截图时的悬浮控制条：显示已拼接高度，提供完成 / 取消；可拖动避开采集区域。
final class LongCapturePanel: NSPanel {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "滚动页面继续采集；完成后点「完成」")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 78),
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

    /// 面板不抢浏览器焦点：用户还要继续滚动页面
    override var canBecomeKey: Bool { true }

    func update(status: String) {
        statusLabel.stringValue = status
    }

    /// 优先放在选区下方，放不下就放到上方；左右不越界
    func place(below selection: CGRect, in visibleFrame: CGRect) {
        let size = frame.size
        var origin = CGPoint(x: selection.minX, y: selection.minY - size.height - 14)
        if origin.y < visibleFrame.minY + 8 {
            origin.y = selection.maxY + 14
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

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        let finishButton = NSButton(title: "完成", target: self, action: #selector(finishTapped))
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
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
    }

    @objc private func finishTapped() {
        onFinish?()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
