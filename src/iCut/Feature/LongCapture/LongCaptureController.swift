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
    private let maxHeight: Int
    private let onFinish: (Output?) -> Void
    /// 抓帧 + 指纹 + 匹配都在后台串行队列：Retina 大选区单帧可到 100ms 量级，留在主线程会掉帧、漏拼
    private let workQueue = DispatchQueue(label: "com.icut.longcapture", qos: .userInitiated)

    private var panel: LongCapturePanel?
    /// 选区提示框：覆盖层关掉后让用户仍能看到正在采集的区域
    private var guide: LongCaptureGuideWindow?
    private var accumulator: StitchAccumulator
    private var timer: Timer?
    /// 只在主线程读写：上一帧还在后台处理时跳过本次 tick，避免任务堆积
    private var isTicking = false
    /// 只在 workQueue 读写
    private var didLogFirstFrame = false
    private var lastCaptureFailureLog = Date.distantPast
    private var debugDumpCount = 0
    /// 只在主线程读写
    private var lastStatusLog = Date.distantPast
    private var lastReason = "等待首帧"
    /// 采集期间禁止 App Nap，否则窗口不活跃时定时器会被节流，看起来“怎么滚都不动”
    private var activity: NSObjectProtocol?
    private(set) var isActive = false

    /// 一帧的处理结果：后台算好后带回主线程更新面板
    private struct FrameResult {
        let append: StitchAccumulator.AppendResult?
        let height: Int
        let captureFailed: Bool
    }

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
        self.maxHeight = maxHeight
        self.onFinish = onFinish
        accumulator = StitchAccumulator(maxHeight: maxHeight)
    }

    func start() {
        guard !isActive else { return }
        isActive = true

        let guide = LongCaptureGuideWindow(rectInAppKit: appKitRect)
        guide.orderFront(nil)
        self.guide = guide

        let panel = LongCapturePanel()
        panel.onFinish = { [weak self] in self?.finish(commit: true) }
        panel.onCancel = { [weak self] in self?.finish(commit: false) }
        self.panel = panel
        panel.orderFront(nil)
        panel.place(near: appKitRect, in: visibleFrame)
        panel.update(
            status: "已拼接 0 px",
            hint: "把鼠标移到要截的页面上，向下滚动，高度会自动增长"
        )
        NSLog("iCut: 长截图开始 rect=\(rectInScreen)")

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 拖动滚动条等 tracking 场景会切 runloop mode，default 下定时器会暂停
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "长截图采集中")
        // 拔插显示器或改分辨率后选区坐标会失效，继续抓帧只会一直失败
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        tick()
    }

    @objc private func screenParametersChanged() {
        NSLog("iCut: 屏幕参数变化，取消长截图")
        finish(commit: false, message: "屏幕变化，长截图已取消")
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

    /// 控制条与提示应限制在屏幕可见区域，避免被菜单栏或 Dock 遮挡
    private var visibleFrame: CGRect {
        NSScreen.screens.first { $0.frame == frame.screenFrame }?.visibleFrame ?? frame.screenFrame
    }

    private func tick() {
        guard isActive, !isTicking else { return }
        isTicking = true
        // 窗口号只能在主线程取；抓屏 API 本身线程安全
        let belowWindow = CGWindowID(panel?.windowNumber ?? 0)
        workQueue.async { [weak self] in
            guard let self else { return }
            let result = self.captureFrame(belowWindow: belowWindow)
            DispatchQueue.main.async {
                self.isTicking = false
                self.apply(result)
            }
        }
    }

    /// 在 workQueue 上执行：抓帧、指纹、匹配
    private func captureFrame(belowWindow: CGWindowID) -> FrameResult {
        // 控制面板自己不能进画面：抓屏时只取它下方的窗口
        guard let image = ScreenCapture.captureRegion(quartzRect, belowWindow: belowWindow) else {
            // 失败会每帧都发生，日志每秒最多一条，避免刷屏
            let now = Date()
            if now.timeIntervalSince(lastCaptureFailureLog) >= 1 {
                lastCaptureFailureLog = now
                NSLog("iCut: 长截图抓帧失败，稍后重试")
            }
            return FrameResult(append: nil, height: accumulator.height, captureFailed: true)
        }
        if !didLogFirstFrame {
            didLogFirstFrame = true
            NSLog("iCut: 长截图首帧 \(image.width)x\(image.height)px")
        }

        let append = accumulator.append(image)
        if case .unchanged(let reason) = append, reason == "未找到重叠区域" {
            dumpDebugFrame(image)
        }
        return FrameResult(append: append, height: accumulator.height, captureFailed: false)
    }

    /// 回到主线程：只更新面板与日志，不做重活
    private func apply(_ result: FrameResult) {
        guard isActive else { return }
        if result.captureFailed {
            panel?.update(status: "抓帧失败", hint: "仍在重试；若一直失败，请确认屏幕录制权限")
            return
        }
        guard let append = result.append else { return }

        switch append {
        case .appended(let rows):
            lastReason = "已追加 +\(rows)"
            panel?.update(
                status: "已拼接 \(result.height) px",
                hint: "继续向下滚动页面；拼够后点「完成」（本轮 +\(rows) px）"
            )
        case .unchanged(let reason):
            lastReason = reason
            panel?.update(
                status: "已拼接 \(result.height) px · \(reason)",
                hint: Self.hint(for: reason, maxHeight: maxHeight)
            )
        }

        // 每秒记一次状态，便于事后判断到底是“页面没滚”还是“匹配不上”
        if Date().timeIntervalSince(lastStatusLog) > 1 {
            lastStatusLog = Date()
            NSLog("iCut: 长截图状态 height=\(result.height) \(lastReason)")
            lastReason = "等待中"
        }
    }

    /// 调试开关（默认关）：`defaults write com.icut.app debug.longCaptureDump -bool YES` 后，
    /// 匹配失败的帧会存到 ~/Library/Caches/longshot-debug/，方便排查真实页面为什么对不上。
    private func dumpDebugFrame(_ image: CGImage) {
        guard UserDefaults.standard.bool(forKey: "debug.longCaptureDump"), debugDumpCount < 20 else { return }
        debugDumpCount += 1
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("longshot-debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = ImageSaver.pngData(from: image, scale: 1) else { return }
        let name = "frame-\(debugDumpCount)-\(Int(Date().timeIntervalSince1970)).png"
        try? data.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - 状态文案

    private static func hint(for reason: String, maxHeight: Int) -> String {
        switch reason {
        case "画面未滚动":
            return "没检测到滚动：先点一下页面再滚，或确认这块区域能滚"
        case "未找到重叠区域":
            return "衔接不上：滚动慢一点，或避开动画 / 视频区域"
        case "已达高度上限":
            return "已达 \(maxHeight)px 上限，点「完成」输出当前长图"
        case "画面尺寸变化":
            return "画面尺寸变了，已跳过该帧"
        default:
            return "继续滚动页面；拼够后点「完成」"
        }
    }

    private func finish(commit: Bool, message: String? = nil) {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if let panel {
            panel.orderOut(nil)
            panel.close()
            self.panel = nil
        }
        if let guide {
            guide.orderOut(nil)
            guide.close()
            self.guide = nil
        }
        if let message {
            LongCaptureToast.show(message, near: appKitRect, in: visibleFrame)
        }

        // 合成排在已入队的抓帧任务之后（串行 FIFO），保证包含最后一帧
        workQueue.async { [weak self] in
            guard let self else { return }
            let image = commit ? self.accumulator.makeImage() : nil
            DispatchQueue.main.async {
                if let image {
                    NSLog("iCut: 长截图合成完成 \(image.width)x\(image.height)px")
                } else {
                    NSLog("iCut: 长截图已结束，未输出")
                }
                self.onFinish(image.map { Output(image: $0, scale: self.frame.backingScaleFactor) })
            }
        }
    }
}
