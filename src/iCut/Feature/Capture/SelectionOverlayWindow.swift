import AppKit
import Carbon

/// 单屏覆盖层：铺一张冻结帧，在上面做纯本地框选绘制。
final class SelectionOverlayWindow: NSWindow {
    let overlayView: SelectionOverlayView

    init(frame: DisplayFrame) {
        overlayView = SelectionOverlayView(frame: frame)
        super.init(
            contentRect: frame.screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = .screenSaver // 盖住菜单栏与 Dock，否则截图时它们会被截进去
        backgroundColor = .black
        hasShadow = false
        isOpaque = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlayView
    }

    // 无边框窗口默认不接受键盘，Esc / Enter 需要它成为 key window
    override var canBecomeKey: Bool { true }
}

final class SelectionOverlayView: NSView {
    private let frameImage: DisplayFrame
    private var state = SelectionState()
    /// 松开鼠标后保留的选区，供 Enter / 双击确认
    private var completedRect: CGRect?

    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: DisplayFrame) {
        frameImage = frame
        super.init(frame: NSRect(origin: .zero, size: frame.screenFrame.size))
    }

    required init?(coder: NSCoder) {
        fatalError("SelectionOverlayView 不支持从 nib 加载")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        drawFrozenFrame()
        drawMask()
        if let selection = state.isUsable ? state.rect : completedRect {
            drawSelectionBorder(selection)
            drawSizeLabel(for: selection)
        }
    }

    private func drawFrozenFrame() {
        // 包成 NSImage 再绘制，flipped 视图下方向才会正确
        NSImage(cgImage: frameImage.image, size: bounds.size).draw(in: bounds)
    }

    private func drawMask() {
        let mask = NSBezierPath(rect: bounds)
        if let selection = state.isUsable ? state.rect : completedRect {
            mask.append(NSBezierPath(rect: selection))
            mask.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        mask.fill()
    }

    private func drawSelectionBorder(_ rect: CGRect) {
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        // 展示像素尺寸：用户关心的是最终出图多大
        let scale = frameImage.backingScaleFactor
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 6, height: 3)

        // 默认放在选区下方，贴到屏幕底部时翻到选区上方
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 8)
        if origin.y + textSize.height + padding.height * 2 > bounds.height {
            origin.y = max(0, rect.minY - textSize.height - padding.height * 2 - 8)
        }

        let labelRect = CGRect(
            x: origin.x,
            y: origin.y,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 3, yRadius: 3).fill()
        text.draw(
            at: CGPoint(x: labelRect.minX + padding.width, y: labelRect.minY + padding.height),
            withAttributes: attributes
        )
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2, let selection = confirmedSelection {
            onConfirm?(selection)
            return
        }

        // 已有选区时，在选区内单击即确认；在选区外按下则重新框选
        if let selection = completedRect, selection.contains(point) {
            onConfirm?(selection)
            return
        }

        state.begin(at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        state.drag(to: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 终点与拖拽同义，直接复用 drag
        state.drag(to: point)
        // 只有形成有效选区才更新待确认选区；点一下不该清掉上一次的框选
        if state.isUsable {
            completedRect = state.rect
        }
        needsDisplay = true
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onCancel?()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let selection = confirmedSelection {
                onConfirm?(selection)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private var confirmedSelection: CGRect? {
        if state.isUsable, let rect = state.rect {
            return rect
        }
        return completedRect
    }
}
