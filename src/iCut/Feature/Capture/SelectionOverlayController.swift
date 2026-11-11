import AppKit

/// 管理一次截图会话内的多块屏覆盖层，并负责把选区裁切成图像。
final class SelectionOverlayController {
    struct CaptureSelection {
        let frame: DisplayFrame
        /// 屏内局部坐标（点，原点左上）
        let rectInScreen: CGRect
        /// 已按 backingScaleFactor 裁好、并渲染上标注的像素图
        let image: CGImage
        let annotations: [Annotation]
    }

    enum CaptureOutcome {
        case confirmed(CaptureSelection)
        case saveRequested(CaptureSelection)
        case pinRequested(CaptureSelection)
        case ocrRequested(CaptureSelection)
        case longCaptureRequested(CaptureSelection)
        case cancelled
    }

    /// 用户结束会话的方式：确认、保存、贴图、识别文字、长截图，或取消（nil）
    private enum FinishRequest {
        case confirm(DisplayFrame, CGRect, [Annotation])
        case save(DisplayFrame, CGRect, [Annotation])
        case pin(DisplayFrame, CGRect, [Annotation])
        case ocr(DisplayFrame, CGRect, [Annotation])
        case longShot(DisplayFrame, CGRect, [Annotation])
    }

    private var windows: [SelectionOverlayWindow] = []
    private var completion: ((CaptureOutcome) -> Void)?
    private(set) var isActive = false

    func begin(frames: [DisplayFrame], completion: @escaping (CaptureOutcome) -> Void) {
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
            window.overlayView.onConfirm = { [weak self] rect, annotations in
                self?.finish(.confirm(frame, rect, annotations))
            }
            window.overlayView.onSave = { [weak self] rect, annotations in
                self?.finish(.save(frame, rect, annotations))
            }
            window.overlayView.onPin = { [weak self] rect, annotations in
                self?.finish(.pin(frame, rect, annotations))
            }
            window.overlayView.onOCR = { [weak self] rect, annotations in
                self?.finish(.ocr(frame, rect, annotations))
            }
            window.overlayView.onLongShot = { [weak self] rect, annotations in
                self?.finish(.longShot(frame, rect, annotations))
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

    private func finish(_ request: FinishRequest?) {
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

        guard let request else {
            completion?(.cancelled)
            return
        }

        let frame: DisplayFrame
        let rect: CGRect
        let annotations: [Annotation]
        enum Kind { case confirm, save, pin, ocr, longShot }
        let kind: Kind
        switch request {
        case .confirm(let confirmedFrame, let confirmedRect, let confirmedAnnotations):
            frame = confirmedFrame
            rect = confirmedRect
            annotations = confirmedAnnotations
            kind = .confirm
        case .save(let savedFrame, let savedRect, let savedAnnotations):
            frame = savedFrame
            rect = savedRect
            annotations = savedAnnotations
            kind = .save
        case .pin(let pinnedFrame, let pinnedRect, let pinnedAnnotations):
            frame = pinnedFrame
            rect = pinnedRect
            annotations = pinnedAnnotations
            kind = .pin
        case .ocr(let ocrFrame, let ocrRect, let ocrAnnotations):
            frame = ocrFrame
            rect = ocrRect
            annotations = ocrAnnotations
            kind = .ocr
        case .longShot(let longFrame, let longRect, let longAnnotations):
            frame = longFrame
            rect = longRect
            annotations = longAnnotations
            kind = .longShot
        }

        guard let selection = crop(frame: frame, rectInScreen: rect, annotations: annotations) else {
            completion?(.cancelled)
            return
        }

        switch kind {
        case .confirm:
            completion?(.confirmed(selection))
        case .save:
            completion?(.saveRequested(selection))
        case .pin:
            completion?(.pinRequested(selection))
        case .ocr:
            completion?(.ocrRequested(selection))
        case .longShot:
            completion?(.longCaptureRequested(selection))
        }
    }

    private func crop(frame: DisplayFrame, rectInScreen rect: CGRect, annotations: [Annotation]) -> CaptureSelection? {
        // 视图坐标与 CGImage 像素坐标同为左上原点，换算与取整统一交给 ScreenGeometry
        let pixelRect = ScreenGeometry.pixelRect(fromPoint: rect, scale: frame.backingScaleFactor)
        guard let cropped = frame.image.cropping(to: pixelRect) else {
            NSLog("iCut: 裁切选区失败 rect=\(pixelRect)")
            return nil
        }
        // 标注先渲染进像素图，后续剪贴板/贴图/保存都直接用最终图
        let finalImage = AnnotationRenderer.render(
            base: cropped,
            annotations: annotations,
            selectionOrigin: rect.origin,
            scale: frame.backingScaleFactor
        )
        return CaptureSelection(frame: frame, rectInScreen: rect, image: finalImage, annotations: annotations)
    }
}
