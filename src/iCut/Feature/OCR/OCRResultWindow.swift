import AppKit

/// OCR 结果窗口：识别到的文本可编辑，确认无误后一键复制。
final class OCRResultWindow: NSWindow, NSWindowDelegate {
    private let resultView = OCRResultView()

    var onClose: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "识别文字"
        isReleasedWhenClosed = false
        delegate = self
        center()
        contentView = resultView
    }

    func show(text: String, message: String) {
        resultView.text = text
        resultView.message = message
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

final class OCRResultView: NSView {
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            copyButton.isEnabled = !newValue.isEmpty
        }
    }

    var message: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("OCRResultView 不支持从 nib 加载")
    }

    private func setUpSubviews() {
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.bezelStyle = .rounded
        copyButton.isEnabled = false

        let bottomBar = NSStackView(views: [statusLabel, copyButton])
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.spacing = 12
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(bottomBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),

            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            bottomBar.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    @objc private func copyText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
        statusLabel.stringValue = "已复制到剪贴板"
    }
}
