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
    private var currentColor: AnnotationColor = .red
    private var textInput: AnnotationTextField?
    private var textAnchor: CGPoint?

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
            drawToolBar(for: selection)
            drawColorRow(for: selection)
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

    private static let toolButtonSize = CGSize(width: 48, height: 26)
    private static let toolButtonSpacing: CGFloat = 5

    /// 工具条整体区域（含按钮间隙），用于吞掉误点，避免重置选区
    private func toolBarContainerRect(for selection: CGRect) -> CGRect {
        let count = Annotation.Kind.allCases.count
        guard count > 0 else { return .zero }
        return toolButtonRect(at: 0, for: selection).union(toolButtonRect(at: count - 1, for: selection))
    }

    /// 工具条按钮的矩形（视图坐标）
    private func toolButtonRect(at index: Int, for selection: CGRect) -> CGRect {
        let count = CGFloat(Annotation.Kind.allCases.count)
        let totalWidth = count * Self.toolButtonSize.width + (count - 1) * Self.toolButtonSpacing

        var originX = selection.minX
        if originX + totalWidth > bounds.width {
            originX = max(0, bounds.width - totalWidth)
        }
        // 选上方放不下就放到选区内顶部
        var originY = selection.minY - Self.toolButtonSize.height - 8
        if originY < 0 {
            originY = selection.minY + 8
        }

        return CGRect(
            x: originX + CGFloat(index) * (Self.toolButtonSize.width + Self.toolButtonSpacing),
            y: originY,
            width: Self.toolButtonSize.width,
            height: Self.toolButtonSize.height
        )
    }

    private func drawToolBar(for selection: CGRect) {
        for (index, kind) in Annotation.Kind.allCases.enumerated() {
            let rect = toolButtonRect(at: index, for: selection)
            let isActive = activeTool == kind

            if isActive {
                NSColor.systemRed.withAlphaComponent(0.95).setFill()
            } else {
                NSColor.black.withAlphaComponent(0.65).setFill()
            }
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

            let title = "\(kind.displayName) \(kind.shortcut)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: isActive ? .bold : .regular),
                .foregroundColor: NSColor.white
            ]
            let size = title.size(withAttributes: attributes)
            title.draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private static let colorDotSize: CGFloat = 20
    private static let colorDotSpacing: CGFloat = 8

    private func colorDotRect(at index: Int, for selection: CGRect) -> CGRect {
        let container = toolBarContainerRect(for: selection)
        return CGRect(
            x: container.minX + CGFloat(index) * (Self.colorDotSize + Self.colorDotSpacing),
            y: container.maxY + 6,
            width: Self.colorDotSize,
            height: Self.colorDotSize
        )
    }

    private func colorRowRect(for selection: CGRect) -> CGRect {
        let count = AnnotationColor.allCases.count
        guard count > 0 else { return .zero }
        return colorDotRect(at: 0, for: selection).union(colorDotRect(at: count - 1, for: selection))
    }

    private func drawColorRow(for selection: CGRect) {
        for (index, color) in AnnotationColor.allCases.enumerated() {
            let rect = colorDotRect(at: index, for: selection)
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            if currentColor == color {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 2
                ring.stroke()
            }
        }
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

        // 工具条区域（含间隙）优先于选区交互，避免误点重置选区
        if let selection = currentSelection {
            let container = toolBarContainerRect(for: selection).insetBy(dx: -10, dy: -10)
            if container.contains(point) {
                for (index, kind) in Annotation.Kind.allCases.enumerated() {
                    if toolButtonRect(at: index, for: selection).contains(point) {
                        toggleTool(kind)
                        return
                    }
                }
                // 点在按钮间隙：吞掉事件，不动选区
                return
            }

            let colorContainer = colorRowRect(for: selection).insetBy(dx: -8, dy: -8)
            if colorContainer.contains(point) {
                for (index, color) in AnnotationColor.allCases.enumerated() {
                    if colorDotRect(at: index, for: selection).contains(point) {
                        currentColor = color
                        needsDisplay = true
                        return
                    }
                }
                return
            }
        }

        // 标注优先：有工具且在选区内
        if let tool = activeTool, let selection = currentSelection, selection.contains(point) {
            if tool == .text {
                beginTextInput(at: point)
                return
            }
            if tool == .number {
                annotations.append(Annotation(kind: .number, points: [point], number: nextNumber, color: currentColor))
                nextNumber += 1
                redoStack.removeAll()
                NSLog("iCut: 添加序号标注")
                needsDisplay = true
                return
            }
            draft = Annotation(kind: tool, points: [point, point], color: currentColor)
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
                let end = event.modifierFlags.contains(.shift)
                    ? constrainedPoint(from: currentDraft.points[0], to: point, kind: currentDraft.kind)
                    : point
                currentDraft.points = [currentDraft.points[0], end]
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

        // 只有真正处于拖拽状态才处理选区；否则（工具条点击、文字输入等）不动已有选区
        guard state.isDragging else {
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
        // 清掉拖拽状态，避免后续 mouseUp 把旧选区当成新框选
        state.reset()
        needsDisplay = true
    }

    /// Shift 约束：矩形/椭圆/马赛克出正方与正圆，直线/箭头吸附 45°
    private func constrainedPoint(from start: CGPoint, to end: CGPoint, kind: Annotation.Kind) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        switch kind {
        case .rectangle, .ellipse, .mosaic:
            let side = max(abs(dx), abs(dy))
            return CGPoint(
                x: start.x + (dx < 0 ? -side : side),
                y: start.y + (dy < 0 ? -side : side)
            )
        case .line, .arrow:
            let length = hypot(dx, dy)
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        default:
            return end
        }
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
        NSLog("iCut: 添加\(annotation.kind.displayName)标注，共 \(annotations.count) 条")
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
        NSLog("iCut: 标注工具 = \(activeTool?.displayName ?? "无")")
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

    private func beginTextInput(at point: CGPoint) {
        commitTextInput()

        // 内联输入框：NSAlert 会被 screenSaver 层的覆盖层盖住，不能用模态弹窗
        let width: CGFloat = 220
        let height: CGFloat = 26
        let originX = min(point.x, max(0, bounds.width - width - 8))
        let originY = min(max(0, point.y - height / 2), max(0, bounds.height - height - 8))

        let field = AnnotationTextField(frame: CGRect(x: originX, y: originY, width: width, height: height))
        field.font = NSFont.systemFont(ofSize: AnnotationPainter.baseFontSize, weight: .semibold)
        field.textColor = currentColor.nsColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        field.drawsBackground = true
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.placeholderString = "输入文字后回车确认，Esc 取消"
        field.target = self
        field.action = #selector(commitTextInput)
        field.onCancel = { [weak self] in self?.cancelTextInput() }
        addSubview(field)
        window?.makeFirstResponder(field)
        textInput = field
        textAnchor = point
    }

    @objc private func commitTextInput() {
        guard let field = textInput, let anchor = textAnchor else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        textInput = nil
        textAnchor = nil
        window?.makeKey()

        guard !text.isEmpty else {
            needsDisplay = true
            return
        }
        annotations.append(Annotation(kind: .text, points: [anchor], text: text, color: currentColor))
        redoStack.removeAll()
        NSLog("iCut: 添加文字标注")
        needsDisplay = true
    }

    private func cancelTextInput() {
        textInput?.removeFromSuperview()
        textInput = nil
        textAnchor = nil
        window?.makeKey()
        needsDisplay = true
    }

    private var confirmedSelection: CGRect? {
        if state.isUsable, let rect = state.rect {
            return rect
        }
        return completedRect
    }
}

/// 内联文字输入框：Esc 走 cancelOperation，回车走 target/action
final class AnnotationTextField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
