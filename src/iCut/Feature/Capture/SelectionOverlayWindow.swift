import AppKit
import Carbon

/// 单屏覆盖层：铺一张冻结帧，在上面做框选、窗口识别与标注。
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
    // MARK: - 底栏动作

    private enum BarAction {
        case tool(Annotation.Kind)
        case undo
        case save
        case pin
        case cancel
        case confirm
    }

    // MARK: - 选区手柄

    private enum SelectionHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private static let handleSize: CGFloat = 7
    private static let handleHitSlop: CGFloat = 12

    // MARK: - 状态

    private let frameImage: DisplayFrame
    private let toolbarPosition = ToolbarSettings.load()
    private var state = SelectionState()
    /// 松开鼠标后保留的选区，供确认与调整
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

    // 选区调整
    private var activeHandle: SelectionHandle?
    private var handleOriginRect: CGRect?
    /// 在选区内按下但还没拖动：松开即确认，拖动则移动选区
    private var pendingConfirm = false
    private var selectionDragStart: CGPoint?

    var onConfirm: ((CGRect, [Annotation]) -> Void)?
    var onSave: ((CGRect, [Annotation]) -> Void)?
    var onPin: ((CGRect, [Annotation]) -> Void)?
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
        // 工具栏与颜色面板上用箭头，避免误以为还在框选
        if completedRect != nil {
            addCursorRect(barFrame(), cursor: .arrow)
            if let palette = paletteFrame() {
                addCursorRect(palette, cursor: .arrow)
            }
        }
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

    // MARK: - 底栏布局

    private static let barItemSize: CGFloat = 34
    private static let barItemSpacing: CGFloat = 4
    private static let barPadding: CGFloat = 10
    private static let barGap: CGFloat = 14

    private var barActions: [BarAction] {
        Annotation.Kind.allCases.map { .tool($0) } + [.undo, .save, .pin, .cancel, .confirm]
    }

    private func barFrame() -> CGRect {
        let count = CGFloat(barActions.count)
        let width = count * Self.barItemSize
            + (count - 1) * Self.barItemSpacing
            + Self.barPadding * 2
            + Self.barGap
        let height = Self.barItemSize + Self.barPadding * 2

        guard let selection = completedRect,
              toolbarPosition == .followSelection else {
            // 固定底部，或还没松手时都放屏幕底部居中
            return CGRect(x: (bounds.width - width) / 2, y: bounds.height - height - 36, width: width, height: height)
        }

        // 默认贴选区下方；下方放不下翻到上方，再放不下就贴选区内底部
        var originX = selection.midX - width / 2
        var originY = selection.maxY + 12
        if originY + height > bounds.height - 8 {
            originY = selection.minY - height - 12
        }
        if originY < 8 {
            originY = max(8, selection.maxY - height - 12)
        }

        originX = min(max(8, originX), max(8, bounds.width - width - 8))
        originY = min(max(8, originY), max(8, bounds.height - height - 8))

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// 每个按钮的矩形；工具与动作之间留一个 gap
    private func barItemRect(at index: Int) -> CGRect {
        let bar = barFrame()
        let toolCount = Annotation.Kind.allCases.count

        var offset = Self.barPadding
        if index >= toolCount {
            offset += Self.barGap
        }
        offset += CGFloat(index) * (Self.barItemSize + Self.barItemSpacing)

        return CGRect(
            x: bar.minX + offset,
            y: bar.minY + Self.barPadding,
            width: Self.barItemSize,
            height: Self.barItemSize
        )
    }

    private func barAction(at point: CGPoint) -> BarAction? {
        // 工具栏只在松手后出现
        guard completedRect != nil else { return nil }
        let bar = barFrame().insetBy(dx: -6, dy: -6)
        guard bar.contains(point) else { return nil }

        let actions = barActions
        for index in actions.indices where barItemRect(at: index).contains(point) {
            return actions[index]
        }
        return nil
    }

    private func drawBottomBar() {
        let bar = barFrame()
        NSColor.black.withAlphaComponent(0.72).setFill()
        let background = NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10)
        background.fill()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        background.lineWidth = 1
        background.stroke()

        let actions = barActions
        for (index, action) in actions.enumerated() {
            let rect = barItemRect(at: index)
            drawBarItem(action, in: rect)
        }
    }

    private func drawBarItem(_ action: BarAction, in rect: CGRect) {
        var isActive = false
        var glyph = ""
        var tint = NSColor.white

        switch action {
        case .tool(let kind):
            glyph = symbol(for: kind)
            isActive = activeTool == kind
        case .undo:
            glyph = "↶"
        case .save:
            glyph = "↓"
        case .pin:
            drawTintedSymbol("pin.fill", in: rect, color: tint, pointSize: 15)
            return
        case .cancel:
            glyph = "✕"
        case .confirm:
            glyph = "✓"
            tint = NSColor.systemBlue
        }

        if isActive {
            NSColor.systemBlue.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: isActive ? .bold : .regular),
            .foregroundColor: tint
        ]
        let size = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func symbol(for kind: Annotation.Kind) -> String {
        switch kind {
        case .rectangle: return "□"
        case .ellipse: return "○"
        case .arrow: return "↗"
        case .line: return "／"
        case .freehand: return "✎"
        case .text: return "T"
        case .mosaic: return "▦"
        case .number: return "①"
        }
    }

    /// SF Symbol 需要手动染色才能在深色底上可见
    private func drawTintedSymbol(_ name: String, in rect: CGRect, color: NSColor, pointSize: CGFloat) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let configured = base.withSymbolConfiguration(config) else { return }
        let size = configured.size

        let tinted = NSImage(size: size, flipped: false) { drawRect in
            color.set()
            configured.draw(in: drawRect)
            drawRect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    // MARK: - 颜色面板（工具激活时弹出）

    private static let paletteDotSize: CGFloat = 24
    private static let paletteDotSpacing: CGFloat = 8

    private func paletteFrame() -> CGRect? {
        guard activeTool != nil else { return nil }
        let bar = barFrame()
        let count = CGFloat(AnnotationColor.allCases.count)
        let width = count * Self.paletteDotSize + (count - 1) * Self.paletteDotSpacing + 16
        return CGRect(x: bar.minX, y: bar.minY - 38, width: width, height: 32)
    }

    private func paletteDotRect(at index: Int) -> CGRect? {
        guard let frame = paletteFrame() else { return nil }
        return CGRect(
            x: frame.minX + 8 + CGFloat(index) * (Self.paletteDotSize + Self.paletteDotSpacing),
            y: frame.midY - Self.paletteDotSize / 2,
            width: Self.paletteDotSize,
            height: Self.paletteDotSize
        )
    }

    private func drawPalette() {
        guard let frame = paletteFrame() else { return }
        NSColor.black.withAlphaComponent(0.72).setFill()
        let background = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        background.fill()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        background.lineWidth = 1
        background.stroke()

        for (index, color) in AnnotationColor.allCases.enumerated() {
            guard let dot = paletteDotRect(at: index) else { continue }
            color.nsColor.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: 2, dy: 2)).fill()
            if currentColor == color {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1.6
                ring.stroke()
            }
        }
    }

    // MARK: - 选区手柄

    private func handleRect(_ handle: SelectionHandle, in rect: CGRect) -> CGRect {
        let half = Self.handleSize / 2
        let point: CGPoint
        switch handle {
        case .topLeft: point = CGPoint(x: rect.minX, y: rect.minY)
        case .top: point = CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: point = CGPoint(x: rect.maxX, y: rect.minY)
        case .right: point = CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: point = CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: point = CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: point = CGPoint(x: rect.minX, y: rect.maxY)
        case .left: point = CGPoint(x: rect.minX, y: rect.midY)
        }
        return CGRect(x: point.x - half, y: point.y - half, width: Self.handleSize, height: Self.handleSize)
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> SelectionHandle? {
        for handle in SelectionHandle.allCases {
            let hitRect = handleRect(handle, in: rect).insetBy(dx: -Self.handleHitSlop, dy: -Self.handleHitSlop)
            if hitRect.contains(point) {
                return handle
            }
        }
        return nil
    }

    private func resizedRect(origin: CGRect, handle: SelectionHandle, to point: CGPoint) -> CGRect {
        var minX = origin.minX
        var maxX = origin.maxX
        var minY = origin.minY
        var maxY = origin.maxY

        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }

        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: max(1, abs(maxX - minX)),
            height: max(1, abs(maxY - minY))
        )
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        drawFrozenFrame()
        drawMask()

        if let selection = state.isUsable ? state.rect : completedRect {
            drawAnnotations(clippedTo: selection)
            drawSelectionBorder(selection)
            if activeTool == nil, completedRect != nil {
                drawHandles(for: selection)
            }
            drawSizeLabel(for: selection)
        } else if let hovered = hoveredWindowRect {
            drawWindowHighlight(hovered)
        }

        if completedRect != nil {
            drawBottomBar()
            drawPalette()
        }
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

    private func drawHandles(for rect: CGRect) {
        for handle in SelectionHandle.allCases {
            let box = handleRect(handle, in: rect)
            NSColor.white.setFill()
            let path = NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5)
            path.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
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
        let padding = CGSize(width: 8, height: 4)

        // 默认放在选区上方，贴到屏幕顶部时翻到选区下方
        var origin = CGPoint(x: rect.minX, y: rect.minY - textSize.height - padding.height * 2 - 8)
        if origin.y < 0 {
            origin.y = min(bounds.height - textSize.height - padding.height * 2, rect.minY + 8)
        }

        let labelRect = CGRect(
            x: origin.x,
            y: origin.y,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        text.draw(
            at: CGPoint(x: labelRect.minX + padding.width, y: labelRect.minY + padding.height),
            withAttributes: attributes
        )
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

    // MARK: - 窗口识别

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

    private func drawWindowHighlight(_ rect: CGRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
        drawSizeLabel(for: rect)
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

        // 文字输入进行中，点别处先提交
        if textInput != nil {
            commitTextInput()
        }

        // 颜色面板（工具激活时弹出在工具栏上方）
        if let frame = paletteFrame(), frame.insetBy(dx: -6, dy: -6).contains(point) {
            for (index, color) in AnnotationColor.allCases.enumerated() {
                if let dot = paletteDotRect(at: index), dot.insetBy(dx: -2, dy: -2).contains(point) {
                    currentColor = color
                    needsDisplay = true
                    return
                }
            }
            return
        }

        // 底栏优先
        if let action = barAction(at: point) {
            perform(action)
            return
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

        // 已有选区时：手柄调整 > 内部按下（待定单击确认/拖动移动）> 外部重新框选
        if activeTool == nil, let selection = completedRect {
            if let handle = handle(at: point, in: selection) {
                activeHandle = handle
                handleOriginRect = selection
                return
            }
            if selection.contains(point) {
                pendingConfirm = true
                selectionDragStart = point
                handleOriginRect = selection
                return
            }
        }

        // 记住按下时的悬停窗口：没拖动就选中整窗
        pressedWindowRect = hoveredWindowRect
        state.begin(at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 手柄调整选区
        if let handle = activeHandle, let origin = handleOriginRect {
            completedRect = resizedRect(origin: origin, handle: handle, to: point)
            needsDisplay = true
            return
        }

        // 选区内拖动 = 移动选区
        if pendingConfirm, let start = selectionDragStart, let origin = handleOriginRect {
            let dx = point.x - start.x
            let dy = point.y - start.y
            if abs(dx) > 2 || abs(dy) > 2 {
                completedRect = origin.offsetBy(dx: dx, dy: dy)
                pendingConfirm = false
                needsDisplay = true
            }
            return
        }

        // 标注绘制
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
        // 工具栏出现或位置变化后，光标区域需要重新登记
        defer { window?.invalidateCursorRects(for: self) }
        let point = convert(event.locationInWindow, from: nil)

        // 手柄调整结束
        if activeHandle != nil {
            activeHandle = nil
            handleOriginRect = nil
            if let rect = completedRect, rect.width < SelectionState.minimumSide || rect.height < SelectionState.minimumSide {
                completedRect = nil
                annotations.removeAll()
                redoStack.removeAll()
                nextNumber = 1
            }
            needsDisplay = true
            return
        }

        // 选区内部单击（没拖动）= 确认
        if pendingConfirm {
            pendingConfirm = false
            selectionDragStart = nil
            handleOriginRect = nil
            if let selection = completedRect {
                onConfirm?(selection, annotations)
            }
            return
        }

        // 移动选区结束
        if selectionDragStart != nil {
            selectionDragStart = nil
            handleOriginRect = nil
            needsDisplay = true
            return
        }

        // 标注提交
        if let currentDraft = draft {
            commitDraft(currentDraft)
            draft = nil
            needsDisplay = true
            return
        }

        // 只有真正处于拖拽状态才处理选区
        guard state.isDragging else {
            needsDisplay = true
            return
        }

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

    // MARK: - 动作

    private func perform(_ action: BarAction) {
        switch action {
        case .tool(let kind):
            activeTool = (activeTool == kind) ? nil : kind
            NSLog("iCut: 标注工具 = \(activeTool?.displayName ?? "无")")
            needsDisplay = true
        case .undo:
            undo()
        case .save:
            if let selection = completedRect ?? (state.isUsable ? state.rect : nil) {
                onSave?(selection, annotations)
            }
        case .pin:
            if let selection = completedRect ?? (state.isUsable ? state.rect : nil) {
                onPin?(selection, annotations)
            }
        case .cancel:
            onCancel?()
        case .confirm:
            if let selection = completedRect ?? (state.isUsable ? state.rect : nil) {
                onConfirm?(selection, annotations)
            }
        }
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

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)

        if event.modifierFlags.contains(.command) {
            switch keyCode {
            case kVK_ANSI_Z:
                if event.modifierFlags.contains(.shift) { redo() } else { undo() }
                return
            case kVK_ANSI_S:
                if let selection = completedRect ?? (state.isUsable ? state.rect : nil) {
                    onSave?(selection, annotations)
                }
                return
            default:
                break
            }
        }

        // 有选区时，字母键切换标注工具
        if completedRect != nil || state.isUsable, let tool = tool(for: keyCode) {
            activeTool = (activeTool == tool) ? nil : tool
            needsDisplay = true
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
            if let selection = completedRect ?? (state.isUsable ? state.rect : nil) {
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

    // MARK: - 文字输入

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

    // MARK: - 辅助

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

    /// 当前可用的选区（拖拽中或已松手）
    private var currentSelection: CGRect? {
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
