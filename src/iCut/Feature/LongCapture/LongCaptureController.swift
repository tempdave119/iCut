import AppKit

/// 长截图：固定屏幕区域定时抓帧，按重叠行拼接；用户滚动页面，点「完成」输出整图。
/// 不模拟滚轮事件（那需要辅助功能权限），滚动完全由用户自己做。
final class LongCaptureController {
    struct Output {
        let image: CGImage
        let scale: CGFloat
    }

    private let frame: DisplayFrame
    private let rectInScreen: CGRect
    private let interval: TimeInterval
    private let onFinish: (Output?) -> Void

    private var panel: LongCapturePanel?
    private var accumulator: StitchAccumulator
    private var timer: Timer?
    private var isTicking = false
    private(set) var isActive = false

    init(
        frame: DisplayFrame,
        rectInScreen: CGRect,
        interval: TimeInterval = 0.2,
        maxHeight: Int = 20000,
        onFinish: @escaping (Output?) -> Void
    ) {
        self.frame = frame
        self.rectInScreen = rectInScreen
        self.interval = interval
        self.onFinish = onFinish
        accumulator = StitchAccumulator(maxHeight: maxHeight)
    }

    func start() {
        guard !isActive else { return }
        isActive = true

        let panel = LongCapturePanel()
        panel.onFinish = { [weak self] in self?.finish(commit: true) }
        panel.onCancel = { [weak self] in self?.finish(commit: false) }
        self.panel = panel
        panel.orderFront(nil)
        panel.place(below: appKitRect, in: frame.screenFrame)
        panel.update(status: "已拼接 0 px")
        NSLog("iCut: 长截图开始 rect=\(rectInScreen)")

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    /// 选区在屏内左上原点，抓屏 API 要 Quartz 全局坐标
    private var quartzRect: CGRect {
        CGRect(
            x: frame.quartzFrame.minX + rectInScreen.minX,
            y: frame.quartzFrame.minY + rectInScreen.minY,
            width: rectInScreen.width,
            height: rectInScreen.height
        )
    }

    /// 选区在 AppKit 全局坐标（左下原点），用于给控制面板定位
    private var appKitRect: CGRect {
        CGRect(
            x: frame.screenFrame.minX + rectInScreen.minX,
            y: frame.screenFrame.maxY - rectInScreen.minY - rectInScreen.height,
            width: rectInScreen.width,
            height: rectInScreen.height
        )
    }

    private func tick() {
        guard isActive, !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        // 控制面板自己不能进画面：抓屏时只取它下方的窗口
        let belowWindow = CGWindowID(panel?.windowNumber ?? 0)
        guard let raw = ScreenCapture.captureRegion(quartzRect, belowWindow: belowWindow) else {
            NSLog("iCut: 长截图抓帧失败，稍后重试")
            return
        }
        let image = normalized(raw)
        guard let image else {
            NSLog("iCut: 长截图帧尺寸异常，跳过本次")
            return
        }

        switch accumulator.append(image) {
        case .appended(let rows):
            panel?.update(status: "已拼接 \(accumulator.height) px（本轮 +\(rows)）")
        case .unchanged(let reason):
            panel?.update(status: "已拼接 \(accumulator.height) px · \(reason)")
        }
    }

    /// 抓屏结果像素尺寸偶尔会和请求的矩形差一点，裁到期望尺寸，保证每帧同宽同高
    private func normalized(_ image: CGImage) -> CGImage? {
        let expected = ScreenGeometry.pixelRect(fromPoint: rectInScreen, scale: frame.backingScaleFactor)
        let width = Int(expected.width)
        let height = Int(expected.height)
        guard width > 0, height > 0 else { return nil }
        guard image.width >= width, image.height >= height else { return nil }
        if image.width == width, image.height == height { return image }
        return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func finish(commit: Bool) {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        if let panel {
            panel.orderOut(nil)
            panel.close()
            self.panel = nil
        }

        guard commit, let image = accumulator.makeImage() else {
            NSLog("iCut: 长截图已结束，未输出")
            onFinish(nil)
            return
        }
        NSLog("iCut: 长截图合成完成 \(image.width)x\(image.height)px")
        onFinish(Output(image: image, scale: frame.backingScaleFactor))
    }
}
