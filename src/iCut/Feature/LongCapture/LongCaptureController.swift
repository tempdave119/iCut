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
    private var didLogFirstFrame = false
    private var lastStatusLog = Date.distantPast
    private var lastReason = "等待首帧"
    /// 采集期间禁止 App Nap，否则窗口不活跃时定时器会被节流，看起来“怎么滚都不动”
    private var activity: NSObjectProtocol?
    private(set) var isActive = false

    init(
        frame: DisplayFrame,
        rectInScreen: CGRect,
        interval: TimeInterval = 0.15,
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
        panel.place(near: appKitRect, in: frame.screenFrame)
        panel.update(
            status: "已拼接 0 px",
            hint: "把鼠标移到要截的页面上，向下滚动，高度会自动增长"
        )
        NSLog("iCut: 长截图开始 rect=\(rectInScreen)")

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "长截图采集中")
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
        guard let image = ScreenCapture.captureRegion(quartzRect, belowWindow: belowWindow) else {
            NSLog("iCut: 长截图抓帧失败，稍后重试")
            panel?.update(status: "抓帧失败", hint: "仍在重试；若一直失败，请确认屏幕录制权限")
            return
        }
        if !didLogFirstFrame {
            didLogFirstFrame = true
            NSLog("iCut: 长截图首帧 \(image.width)x\(image.height)px")
        }

        switch accumulator.append(image) {
        case .appended(let rows):
            lastReason = "已追加 +\(rows)"
            panel?.update(
                status: "已拼接 \(accumulator.height) px",
                hint: "继续向下滚动页面；拼够后点「完成」（本轮 +\(rows) px）"
            )
        case .unchanged(let reason):
            lastReason = reason
            panel?.update(
                status: "已拼接 \(accumulator.height) px · \(reason)",
                hint: Self.hint(for: reason)
            )
        }

        // 每秒记一次状态，便于事后判断到底是“页面没滚”还是“匹配不上”
        if Date().timeIntervalSince(lastStatusLog) > 1 {
            lastStatusLog = Date()
            NSLog("iCut: 长截图状态 height=\(accumulator.height) \(lastReason)")
            lastReason = "等待中"
        }
    }

    private static func hint(for reason: String) -> String {
        switch reason {
        case "画面未滚动":
            return "没检测到滚动：先点一下页面再滚，或确认这块区域能滚"
        case "未找到重叠区域":
            return "衔接不上：滚动慢一点，或避开动画 / 视频区域"
        case "已达高度上限":
            return "已达 20000px 上限，点「完成」输出当前长图"
        case "画面尺寸变化":
            return "画面尺寸变了，已跳过该帧"
        default:
            return "继续滚动页面；拼够后点「完成」"
        }
    }

    private func finish(commit: Bool) {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
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
