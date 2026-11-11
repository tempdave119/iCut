import AppKit
import Carbon

/// 快捷键录制窗口：只负责把原始键盘事件交给调用方，注册与持久化由 AppDelegate 决定。
final class ShortcutRecorderWindow: NSWindow, NSWindowDelegate {
    private let recorderView = ShortcutRecorderView()

    var onKeyDown: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?

    init(current: HotKeyConfig) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "设置快捷键"
        isReleasedWhenClosed = false
        delegate = self
        center()

        contentView = recorderView
        recorderView.currentText = current.displayText
        recorderView.onKeyDown = { [weak self] event in
            self?.onKeyDown?(event)
        }
    }

    /// 错误提示显示在窗口内，避免弹窗抢走键盘焦点导致录制中断
    func showMessage(_ text: String) {
        recorderView.showMessage(text)
    }

    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(recorderView)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

final class ShortcutRecorderView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?
    var currentText = "" {
        didSet { currentLabel.stringValue = currentText }
    }

    private let currentLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("ShortcutRecorderView 不支持从 nib 加载")
    }

    override func keyDown(with event: NSEvent) {
        messageLabel.stringValue = ""
        // 裸 Esc 留给「取消」，不参与快捷键录制
        if Int(event.keyCode) == kVK_Escape {
            window?.close()
            return
        }
        onKeyDown?(event)
    }

    func showMessage(_ text: String) {
        messageLabel.stringValue = text
    }

    private func setUpSubviews() {
        currentLabel.font = .systemFont(ofSize: 26, weight: .medium)
        currentLabel.alignment = .center

        hintLabel.stringValue = "按下新的快捷键组合，需包含 ⌘ ⌥ ⌃ ⇧ 至少一个；Esc 取消"
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 2
        hintLabel.lineBreakMode = .byWordWrapping

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .systemRed
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byWordWrapping

        for label in [currentLabel, hintLabel, messageLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            currentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            currentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            currentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 28),

            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            hintLabel.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 10),

            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            messageLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 8)
        ])
    }
}
