import AppKit
import Carbon

/// 贴图浮窗：无边框、置顶、可拖动、滚轮缩放、⌥+滚轮调透明度、旋转、Esc 或右键菜单关闭。
final class PinWindow: NSWindow, NSWindowDelegate {
    private let pinView: PinContentView
    /// 窗口关闭后通知控制器从列表里移除
    var onClose: (() -> Void)?
    /// 识别贴图上的文字；图像由内容视图持有，旋转后也取到最新一张
    var onRequestOCR: ((CGImage) -> Void)?

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
        pinView.onRequestOCR = { [weak self] image in self?.onRequestOCR?(image) }
    }

    // 需要接收 Esc 与滚轮，无边框窗口默认不接受键盘
    override var canBecomeKey: Bool { true }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

final class PinContentView: NSView {
    private var image: CGImage
    private let scale: CGFloat
    private var dragOffset: CGPoint?

    var onRequestClose: (() -> Void)?
    /// 贴图上的文字识别由控制器转给 AppDelegate，与截图工具栏共用同一服务
    var onRequestOCR: ((CGImage) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // 非 key 窗口的第一击默认只用于激活窗口，会让用户觉得「第一次点不动贴图」
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let minimumSide: CGFloat = 40
    private static let minimumAlpha: CGFloat = 0.2

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

    // MARK: - 滚轮：缩放 / 透明度

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }

        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 3
        guard delta != 0 else { return }

        // ⌥+滚轮连续调透明度，普通滚轮仍是缩放
        if event.modifierFlags.contains(.option) {
            window.alphaValue = max(Self.minimumAlpha, min(1.0, window.alphaValue + delta * 0.02))
            return
        }

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

    // MARK: - 旋转

    private func rotate90() {
        guard let window, let rotated = rotatedImage() else { return }
        image = rotated

        // 宽高互换，保持中心不动
        var frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = CGSize(width: frame.height, height: frame.width)
        frame.origin = CGPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        window.setFrame(frame, display: true)
        needsDisplay = true
    }

    private func rotatedImage() -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: height,
            height: width,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: CGFloat(height) / 2, y: CGFloat(width) / 2)
        context.rotate(by: .pi / 2)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(width) / 2,
                y: -CGFloat(height) / 2,
                width: CGFloat(width),
                height: CGFloat(height)
            )
        )
        return context.makeImage()
    }

    // MARK: - 键盘与菜单

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onRequestClose?()
        case kVK_ANSI_R:
            rotate90()
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(makeItem("复制", #selector(copyImage)))

        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = percent
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(makeItem("旋转 90°", #selector(rotateAction)))
        menu.addItem(makeItem("识别文字", #selector(recognizeText)))
        menu.addItem(makeItem("保存…", #selector(saveImage)))
        menu.addItem(.separator())
        menu.addItem(makeItem("关闭", #selector(closePin)))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyImage() {
        ClipboardService.copy(image: image, scale: scale)
    }

    @objc private func saveImage() {
        ImageSaver.savePNG(image: image, scale: scale, defaultName: ImageSaver.defaultFileName())
    }

    @objc private func rotateAction() {
        rotate90()
    }

    @objc private func recognizeText() {
        onRequestOCR?(image)
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        window?.alphaValue = CGFloat(percent) / 100
    }

    @objc private func closePin() {
        onRequestClose?()
    }
}
