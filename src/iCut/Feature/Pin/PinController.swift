import AppKit

/// 管理所有贴图窗口，并提供截图期间的批量隐藏/恢复。
final class PinController {
    private var pins: [PinWindow] = []
    private var hiddenForCapture: [PinWindow] = []

    var count: Int { pins.count }
    /// 贴图右键「识别文字」的出口，由 AppDelegate 接到统一的识别服务
    var onRequestOCR: ((CGImage) -> Void)?

    func pin(image: CGImage, scale: CGFloat, origin: CGPoint) {
        let window = PinWindow(image: image, scale: scale, origin: origin)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.pins.removeAll { $0 === window }
        }
        window.onRequestOCR = { [weak self] image in self?.onRequestOCR?(image) }
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

    /// 菜单里的批量隐藏/恢复，与截图期的临时隐藏区分开
    func hideAll() {
        pins.forEach { $0.orderOut(nil) }
    }

    func showAll() {
        pins.forEach { $0.orderFront(nil) }
    }
}
