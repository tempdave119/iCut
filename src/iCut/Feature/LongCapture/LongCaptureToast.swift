import AppKit

/// 长截图完成后的一次性提示：只显示一两秒，告诉用户图去了剪贴板（以及是否落盘）。
final class LongCaptureToast: NSPanel {
    private static var current: LongCaptureToast?

    private let label = NSTextField(labelWithString: "")

    static func show(_ text: String, near rect: CGRect, in visibleFrame: CGRect) {
        current?.close()
        let toast = LongCaptureToast(text: text)
        toast.position(near: rect, in: visibleFrame)
        toast.orderFront(nil)
        current = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak toast] in
            toast?.close()
            if current === toast { current = nil }
        }
    }

    private init(text: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .vibrantDark)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        contentView = effect

        label.stringValue = text
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
    }

    private func position(near rect: CGRect, in visibleFrame: CGRect) {
        let size = frame.size
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 16)
        if origin.y < visibleFrame.minY + 8 {
            origin.y = rect.maxY + 16
        }
        origin.x = min(max(visibleFrame.minX + 8, origin.x), visibleFrame.maxX - size.width - 8)
        origin.y = min(max(visibleFrame.minY + 8, origin.y), visibleFrame.maxY - size.height - 8)
        setFrameOrigin(origin)
    }
}
