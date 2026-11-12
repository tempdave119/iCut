import AppKit

/// 轮询系统剪贴板变化：NSPasteboard 没有变化通知，只能比对 changeCount。
/// 解析放在后台队列，主线程只负责定时比对计数。
final class PasteboardWatcher {
    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private let parseQueue = DispatchQueue(label: "com.icut.app.clipboard.parse")

    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?
    private var recordImages = true
    private var onSnapshot: ((PasteboardSnapshot) -> Void)?

    init(pasteboard: NSPasteboard = .general, interval: TimeInterval = 0.3) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        stop()
    }

    var isRunning: Bool { timer != nil }

    func start(recordImages: Bool, onSnapshot: @escaping (PasteboardSnapshot) -> Void) {
        self.recordImages = recordImages
        self.onSnapshot = onSnapshot

        if timer != nil { return }
        // 从启动那一刻的计数开始，避免把开启前的旧内容当成一次新复制
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onSnapshot = nil
    }

    /// 自己写完剪贴板后调用：下一次命中的变化直接丢弃，避免回填产生重复条目。
    func noteSelfWrite() {
        suppressedChangeCount = pasteboard.changeCount
    }

    private func tick() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        if suppressedChangeCount == count {
            suppressedChangeCount = nil
            return
        }

        let pasteboard = self.pasteboard
        let recordImages = self.recordImages
        parseQueue.async { [weak self] in
            guard let snapshot = PasteboardSnapshot.parse(pasteboard, recordImages: recordImages) else {
                return
            }
            self?.onSnapshot?(snapshot)
        }
    }
}
