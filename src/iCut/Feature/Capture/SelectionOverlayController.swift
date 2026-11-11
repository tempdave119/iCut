import AppKit

/// 管理一次截图会话内的多块屏覆盖层，并负责把选区裁切成图像。
final class SelectionOverlayController {
    struct CaptureSelection {
        let frame: DisplayFrame
        /// 屏内局部坐标（点，原点左上）
        let rectInScreen: CGRect
        /// 已按 backingScaleFactor 裁好的像素图
        let image: CGImage
    }

    private var windows: [SelectionOverlayWindow] = []
    private var completion: ((CaptureSelection?) -> Void)?
    private(set) var isActive = false

    func begin(frames: [DisplayFrame], completion: @escaping (CaptureSelection?) -> Void) {
        guard !isActive, !frames.isEmpty else { return }
        isActive = true
        self.completion = completion

        // 插拔显示器或改分辨率会让覆盖层坐标失真，直接取消本次会话
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        windows = frames.map { frame in
            let window = SelectionOverlayWindow(frame: frame)
            window.overlayView.onConfirm = { [weak self] rect in
                self?.finish((frame, rect))
            }
            window.overlayView.onCancel = { [weak self] in
                self?.finish(nil)
            }
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    @objc private func screenParametersChanged() {
        NSLog("iCut: 屏幕参数变化，取消本次截图")
        finish(nil)
    }

    private func finish(_ result: (frame: DisplayFrame, rect: CGRect)?) {
        guard isActive else { return }
        isActive = false

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        let completion = self.completion
        self.completion = nil

        guard let (frame, rect) = result else {
            completion?(nil)
            return
        }

        // 视图坐标与 CGImage 像素坐标同为左上原点，换算与取整统一交给 ScreenGeometry
        let pixelRect = ScreenGeometry.pixelRect(fromPoint: rect, scale: frame.backingScaleFactor)
        guard let cropped = frame.image.cropping(to: pixelRect) else {
            NSLog("iCut: 裁切选区失败 rect=\(pixelRect)")
            completion?(nil)
            return
        }
        completion?(CaptureSelection(frame: frame, rectInScreen: rect, image: cropped))
    }
}
