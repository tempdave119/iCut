import AppKit

/// 长截图期间给选区画一圈提示框：让用户知道正在采集哪块区域。
/// 窗口忽略鼠标事件，滚动页面时事件会穿过去，不会挡住操作。
final class LongCaptureGuideWindow: NSWindow {
    init(rectInAppKit: CGRect) {
        super.init(
            contentRect: rectInAppKit.insetBy(dx: -1, dy: -1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // 比控制条高一层：抓屏只取控制条以下的窗口，guide 在控制条之上，所以两者都不会进画面
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = LongCaptureGuideView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LongCaptureGuideView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        path.stroke()
    }
}
