import AppKit
import Carbon

/// 贴图浮窗：无边框、置顶、可拖动、滚轮缩放、Esc 或右键菜单关闭。
final class PinWindow: NSWindow, NSWindowDelegate {
    private let pinView: PinContentView
    /// 窗口关闭后通知控制器从列表里移除
    var onClose: (() -> Void)?

    init(image: CGImage, scale: CGFloat, origin: CGPoint) {
        let pointSize = CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        pinView = PinContentView(image: image, scale: scale)

        super.init(
            contentRect: CGRect(origin: origin, size: pointSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        delegate = self
        level = .floating
        backgroundColor = .black
        isOpaque = true
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = pinView

        pinView.onRequestClose = { [weak self] in self?.close() }
    }

    // 需要接收 Esc 与滚轮，无边框窗口默认不接受键盘
    override var canBecomeKey: Bool { true }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

final class PinContentView: NSView {
    private let image: CGImage
    private let scale: CGFloat
    private var dragOffset: CGPoint?

    var onRequestClose: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private static let minimumSide: CGFloat = 40

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("PinContentView 不支持从 nib 加载")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
    }

    // MARK: - 拖动

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragOffset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset = dragOffset, let window else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: mouse.x - offset.x, y: mouse.y - offset.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }

    // MARK: - 缩放

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 3
        guard delta != 0 else { return }

        let frame = window.frame
        let maxSide = max(window.screen?.visibleFrame.width ?? frame.width, frame.width) * 2
        let newFrame = ScreenGeometry.zoomedFrame(
            current: frame,
            cursor: NSEvent.mouseLocation,
            factor: 1 + delta * 0.01,
            minSide: Self.minimumSide,
            maxSide: maxSide
        )
        window.setFrame(newFrame, display: true)
    }

    // MARK: - 键盘与菜单

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            onRequestClose?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制", action: #selector(copyImage), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(.separator())
        let closeItem = NSMenuItem(title: "关闭", action: #selector(closePin), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
        return menu
    }

    @objc private func copyImage() {
        ClipboardService.copy(image: image, scale: scale)
    }

    @objc private func closePin() {
        onRequestClose?()
    }
}
