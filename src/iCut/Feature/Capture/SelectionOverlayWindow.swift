import AppKit
import Carbon

/// 单屏覆盖层：铺一张冻结帧，在上面做纯本地框选绘制。
final class SelectionOverlayWindow: NSWindow {
    let overlayView: SelectionOverlayView

    init(frame: DisplayFrame) {
        overlayView = SelectionOverlayView(frame: frame)
        super.init(
            contentRect: frame.screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = .screenSaver // 盖住菜单栏与 Dock，否则截图时它们会被截进去
        backgroundColor = .black
        hasShadow = false
        isOpaque = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true // 窗口智能识别靠悬停，必须接收鼠标移动
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlayView
    }

    // 无边框窗口默认不接受键盘，Esc / Enter 需要它成为 key window
    override var canBecomeKey: Bool { true }
}

final class SelectionOverlayView: NSView {
    private let frameImage: DisplayFrame
    private var state = SelectionState()
    /// 松开鼠标后保留的选区，供 Enter / 双击确认
    private var completedRect: CGRect?
    /// 悬停高亮的窗口（未按下时跟随鼠标）
    private var hoveredWindowRect: CGRect?
    /// 按下时记住的窗口；没拖动就选中整窗，拖了就转手动框选
    private var pressedWindowRect: CGRect?
    private var trackingArea: NSTrackingArea?

    // 标注状态
    private var activeTool: Annotation.Kind?
    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var draft: Annotation?
    private var nextNumber = 1

    var onConfirm: ((CGRect, [Annotation]) -> Void)?
    var onSave: ((CGRect, [Annotation]) -> Void)?
    var onCancel: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: DisplayFrame) {
        frameImage = frame
        super.init(frame: NSRect(origin: .zero, size: frame.screenFrame.size))
    }

    required init?(coder: NSCoder) {
        fatalError("SelectionOverlayView 不支持从 nib 加载")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// 光标下窗口的屏内矩形（视图 flipped 坐标）
    private func detectedWindowRect(at localPoint: CGPoint) -> CGRect? {
        let quartzPoint = CGPoint(
            x: localPoint.x + frameImage.quartzFrame.minX,
            y: localPoint.y + frameImage.quartzFrame.minY
        )
        guard let detected = WindowDetector.window(at: quartzPoint, excludingPID: getpid()) else {
            return nil
        }
        return CGRect(
            x: detected.bounds.minX - frameImage.quartzFrame.minX,
            y: detected.bounds.minY - frameImage.quartzFrame.minY,
            width: detected.bounds.width,
            height: detected.bounds.height
        )
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        drawFrozenFrame()
        drawMask()
        if let selection = state.isUsable ? state.rect : completedRect {
            drawAnnotations(clippedTo: selection)
            drawSelectionBorder(selection)
            drawSizeLabel(for: selection)
            drawToolHint(for: selection)
        } else if let hovered = hoveredWindowRect {
            drawWindowHighlight(hovered)
        }
    }

    private func drawAnnotations(clippedTo selection: CGRect) {
        guard !annotations.isEmpty || draft != nil else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        for annotation in annotations {
            AnnotationPainter.draw(
                annotation,
                offset: .zero,
                scale: 1,
                mosaicSource: frameImage.image,
                mosaicSourceScale: frameImage.backingScaleFactor
            )
        }
        if let draft {
            AnnotationPainter.draw(
                draft,
                offset: .zero,
                scale: 1,
                mosaicSource: frameImage.image,
                mosaicSourceScale: frameImage.backingScaleFactor
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawToolHint(for selection: CGRect) {
        let hint: String
        if let activeTool {
            hint = "\(activeTool.displayName)（\(activeTool.shortcut)）：拖拽绘制 · ⌘Z 撤销 · Esc 退出工具"
        } else {
            hint = "R 矩形 O 椭圆 A 箭头 L 直线 P 画笔 T 文字 M 马赛克 N 序号 · ⌘S 保存"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = hint.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: selection.minX,
            y: max(0, selection.minY - size.height - 10),
            width: size.width + 12,
            height: size.height + 6
        )
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        hint.draw(at: CGPoint(x: labelRect.minX + 6, y: labelRect.minY + 3), withAttributes: attributes)
    }

    private func drawWindowHighlight(_ rect: CGRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
        drawSizeLabel(for: rect)
    }

    private func drawFrozenFrame() {
        // 包成 NSImage 再绘制，flipped 视图下方向才会正确
        NSImage(cgImage: frameImage.image, size: bounds.size).draw(in: bounds)
    }

    private func drawMask() {
        let mask = NSBezierPath(rect: bounds)
        if let selection = state.isUsable ? state.rect : completedRect {
            mask.append(NSBezierPath(rect: selection))
            mask.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        mask.fill()
    }

    private func drawSelectionBorder(_ rect: CGRect) {
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        // 展示像素尺寸：用户关心的是最终出图多大
        let scale = frameImage.backingScaleFactor
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 6, height: 3)

        // 默认放在选区下方，贴到屏幕底部时翻到选区上方
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 8)
        if origin.y + textSize.height + padding.height * 2 > bounds.height {
            origin.y = max(0, rect.minY - textSize.height - padding.height * 2 - 8)
        }

        let labelRect = CGRect(
            x: origin.x,
            y: origin.y,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 3, yRadius: 3).fill()
        text.draw(
            at: CGPoint(x: labelRect.minX + padding.width, y: labelRect.minY + padding.height),
            withAttributes: attributes
        )
    }

    // MARK: - 鼠标

    override func mouseMoved(with event: NSEvent) {
        guard completedRect == nil, !state.isDragging, pressedWindowRect == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        hoveredWindowRect = detectedWindowRect(at: point)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)

        // 标注优先：有工具且在选区内
        if let tool = activeTool, let selection = currentSelection, selection.contains(point) {
            if tool == .text {
                promptText(at: point)
                return
            }
            if tool == .number {
                annotations.append(Annotation(kind: .number, points: [point], number: nextNumber))
                nextNumber += 1
                redoStack.removeAll()
                needsDisplay = true
                return
            }
            draft = Annotation(kind: tool, points: [point, point])
            needsDisplay = true
            return
        }

        if event.clickCount == 2, activeTool == nil, let selection = confirmedSelection {
            onConfirm?(selection, annotations)
            return
        }

        // 已有选区时，在选区内单击即确认；在选区外按下则重新框选
        if activeTool == nil, let selection = completedRect, selection.contains(point) {
            onConfirm?(selection, annotations)
            return
        }

        // 记住按下时的悬停窗口：没拖动就选中整窗
        pressedWindowRect = hoveredWindowRect
        state.begin(at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if var currentDraft = draft {
            if currentDraft.kind == .freehand {
                currentDraft.points.append(point)
            } else {
                currentDraft.points = [currentDraft.points[0], point]
            }
            draft = currentDraft
            needsDisplay = true
            return
        }

        state.drag(to: point)
        // 拖动超过阈值就放弃窗口选择，转为手动框选
        if let rect = state.rect,
           rect.width > SelectionState.minimumSide || rect.height > SelectionState.minimumSide {
            pressedWindowRect = nil
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let currentDraft = draft {
            commitDraft(currentDraft)
            draft = nil
            needsDisplay = true
            return
        }

        // 终点与拖拽同义，直接复用 drag
        state.drag(to: point)

        if let windowRect = pressedWindowRect {
            completedRect = windowRect
            state.reset()
            pressedWindowRect = nil
            hoveredWindowRect = nil
            annotations.removeAll()
            redoStack.removeAll()
            nextNumber = 1
            needsDisplay = true
            return
        }

        // 只有形成有效选区才更新待确认选区；点一下不该清掉上一次的框选
        if state.isUsable {
            completedRect = state.rect
            annotations.removeAll()
            redoStack.removeAll()
            nextNumber = 1
        }
        needsDisplay = true
    }

    private func commitDraft(_ annotation: Annotation) {
        if annotation.kind == .freehand {
            guard annotation.points.count >= 2 else { return }
        } else {
            let rect = annotation.boundingRect
            guard rect.width >= 2 || rect.height >= 2 else { return }
        }
        annotations.append(annotation)
        redoStack.removeAll()
    }

    /// 当前可确认的选区（拖拽中或已松手）
    private var currentSelection: CGRect? {
        if state.isUsable, let rect = state.rect {
            return rect
        }
        return completedRect
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)

        if event.modifierFlags.contains(.command) {
            switch keyCode {
            case kVK_ANSI_Z:
                if event.modifierFlags.contains(.shift) { redo() } else { undo() }
                return
            case kVK_ANSI_S:
                if let selection = confirmedSelection {
                    onSave?(selection, annotations)
                }
                return
            default:
                break
            }
        }

        // 有选区时，字母键切换标注工具
        if completedRect != nil || state.isUsable, let tool = tool(for: keyCode) {
            toggleTool(tool)
            return
        }

        switch keyCode {
        case kVK_Escape:
            // 先退出工具，再退出截图
            if activeTool != nil {
                activeTool = nil
                needsDisplay = true
            } else {
                onCancel?()
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let selection = confirmedSelection {
                onConfirm?(selection, annotations)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func tool(for keyCode: Int) -> Annotation.Kind? {
        switch keyCode {
        case kVK_ANSI_R: return .rectangle
        case kVK_ANSI_O: return .ellipse
        case kVK_ANSI_A: return .arrow
        case kVK_ANSI_L: return .line
        case kVK_ANSI_P: return .freehand
        case kVK_ANSI_T: return .text
        case kVK_ANSI_M: return .mosaic
        case kVK_ANSI_N: return .number
        default: return nil
        }
    }

    private func toggleTool(_ tool: Annotation.Kind) {
        activeTool = (activeTool == tool) ? nil : tool
        needsDisplay = true
    }

    private func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        if last.kind == .number {
            nextNumber = max(1, nextNumber - 1)
        }
        needsDisplay = true
    }

    private func redo() {
        guard let restored = redoStack.popLast() else { return }
        annotations.append(restored)
        if restored.kind == .number {
            nextNumber += 1
        }
        needsDisplay = true
    }

    private func promptText(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "输入文字"
        alert.informativeText = "文字将标注在点击位置"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                annotations.append(Annotation(kind: .text, points: [point], text: text))
                redoStack.removeAll()
                needsDisplay = true
            }
        }
        // 模态框关闭后把键盘焦点还给覆盖层
        window?.makeKey()
    }

    private var confirmedSelection: CGRect? {
        if state.isUsable, let rect = state.rect {
            return rect
        }
        return completedRect
    }
}
