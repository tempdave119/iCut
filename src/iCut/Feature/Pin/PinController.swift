import AppKit

/// 管理所有贴图窗口，并提供截图期间的批量隐藏/恢复。
final class PinController {
    private var pins: [PinWindow] = []
    private var hiddenForCapture: [PinWindow] = []

    var count: Int { pins.count }

    func pin(image: CGImage, scale: CGFloat, origin: CGPoint) {
        let window = PinWindow(image: image, scale: scale, origin: origin)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.pins.removeAll { $0 === window }
        }
        pins.append(window)
        // 不抢焦点：用户通常接着做别的事
        window.orderFront(nil)
    }

    /// 截图前隐藏已有贴图，避免它们被截进冻结帧
    func hideAllForCapture() {
        hiddenForCapture = pins.filter { $0.isVisible }
        hiddenForCapture.forEach { $0.orderOut(nil) }
    }

    func restoreAfterCapture() {
        let windows = hiddenForCapture
        hiddenForCapture.removeAll()
        windows.forEach { $0.orderFront(nil) }
    }
}
