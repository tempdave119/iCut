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
        case shapes
        case tool(Annotation.Kind)
        case colors
        case undo
        case longShot
        case ocr
        case save
        case pin
        case cancel
        case confirm
    }

    /// 工具栏下方的一次性弹层；同一时间只开一个
    private enum PopupPanel {
        case shapes
        case colors
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
    /// 形状按钮在工具未激活时回显上次选的形状
    private var lastShape: Annotation.Kind = .rectangle
    private var openPanel: PopupPanel?
    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var draft: Annotation?
    private var nextNumber = 1
    private var currentColor: AnnotationColor = .red
    private var textInput: AnnotationTextField?
    private var textAnchor: CGPoint?

    // 悬停高亮（自绘按钮没有子视图，需要自己跟踪）
    private var hoveredBarIndex: Int?
    private var hoveredPanelIndex: Int?

    // 选区调整
    private var activeHandle: SelectionHandle?
    private var handleOriginRect: CGRect?
    /// 在选区内按下但还没拖动：松开即确认，拖动则移动选区
    private var pendingConfirm = false
    private var selectionDragStart: CGPoint?

    var onConfirm: ((CGRect, [Annotation]) -> Void)?
    var onSave: ((CGRect, [Annotation]) -> Void)?
    var onPin: ((CGRect, [Annotation]) -> Void)?
    var onLongShot: ((CGRect, [Annotation]) -> Void)?
    var onOCR: ((CGRect, [Annotation]) -> Void)?
    var onCancel: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // 窗口不在 key 状态时，第一击默认只激活窗口，会让工具栏的第一次点击丢失
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: DisplayFrame) {
        frameImage = frame
        super.init(frame: NSRect(origin: .zero, size: frame.screenFrame.size))
    }

    required init?(coder: NSCoder) {
        fatalError("SelectionOverlayView 不支持从 nib 加载")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        // 工具栏与弹层上用箭头，避免误以为还在框选
        if completedRect != nil {
            addCursorRect(barFrame(), cursor: .arrow)
            if let panel = panelFrame() {
                addCursorRect(panel, cursor: .arrow)
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
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
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
    /// 工具区 8 项（形状 + 4 个独立工具 + 长截图 + 文字识别 + 颜色），之后是动作区
    private static let toolbarSectionCount = 8
    private static let shapeTools: [Annotation.Kind] = [.rectangle, .ellipse, .line, .arrow]

    private var barActions: [BarAction] {
        var actions: [BarAction] = [.shapes]
        actions += [.tool(.freehand), .tool(.text), .tool(.mosaic), .tool(.number)]
        // 识别文字属于工具区，放在序号之后、颜色之前；工具区与动作区之间由 barGap 分隔
        actions += [.longShot, .ocr, .colors, .undo, .save, .pin, .cancel, .confirm]
        return actions
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
            // 固定底部时抬高留出弹层高度，保证面板能在工具条下方展开
            return CGRect(x: (bounds.width - width) / 2, y: bounds.height - height - 84, width: width, height: height)
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

    /// 每个按钮的矩形；工具区与动作区之间留一个 gap
    private func barItemRect(at index: Int) -> CGRect {
        let bar = barFrame()

        var offset = Self.barPadding
        if index >= Self.toolbarSectionCount {
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

    private static let iconColor = NSColor(calibratedWhite: 0.25, alpha: 1)
    private static let disabledIconColor = NSColor(calibratedWhite: 0.72, alpha: 1)

    private func drawBottomBar() {
        let bar = barFrame()
        drawPopupBackground(bar, cornerRadius: 10)
        for (index, action) in barActions.enumerated() {
            drawBarItem(action, index: index, in: barItemRect(at: index))
        }
    }

    /// 工具条与弹层共用的浅色底：白底 + 阴影 + 细描边
    private func drawPopupBackground(_ rect: CGRect, cornerRadius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: 2)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.12).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 1
        border.stroke()
    }

    /// 悬停时铺一层浅灰底并加阴影，做出浮起效果
    private func drawHoverBackground(in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: 2)
        shadow.set()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBarItem(_ action: BarAction, index: Int, in rect: CGRect) {
        let isActive = isActive(action)
        let isEnabled = isEnabled(action)
        let isHovered = hoveredBarIndex == index && isEnabled
        let iconColor = isActive ? NSColor.white : (isEnabled ? Self.iconColor : Self.disabledIconColor)

        if isActive {
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        } else if isHovered {
            drawHoverBackground(in: rect.insetBy(dx: 2, dy: 2))
        }

        switch action {
        case .shapes:
            let shown = activeTool.flatMap { Self.shapeTools.contains($0) ? $0 : nil } ?? lastShape
            drawGlyph(symbol(for: shown), in: rect, color: iconColor, weight: .medium)
        case .tool(let kind):
            drawGlyph(symbol(for: kind), in: rect, color: iconColor, weight: .medium)
        case .colors:
            drawColorDot(in: rect)
        case .undo:
            drawTintedSymbol("arrow.uturn.backward", in: rect, color: iconColor, pointSize: 15)
        case .longShot:
            drawGlyph("长", in: rect, color: iconColor, weight: .medium)
        case .ocr:
            drawTintedSymbol("text.viewfinder", in: rect, color: iconColor, pointSize: 15)
        case .save:
            drawTintedSymbol("square.and.arrow.down", in: rect, color: iconColor, pointSize: 15)
        case .pin:
            drawTintedSymbol("pin.fill", in: rect, color: iconColor, pointSize: 15)
        case .cancel:
            drawGlyph("✕", in: rect, color: iconColor, weight: .regular)
        case .confirm:
            drawGlyph("✓", in: rect, color: .systemBlue, weight: .semibold)
        }
    }

    private func isActive(_ action: BarAction) -> Bool {
        switch action {
        case .shapes: return activeTool.map { Self.shapeTools.contains($0) } ?? false
        case .tool(let kind): return activeTool == kind
        case .colors: return openPanel == .colors
        default: return false
        }
    }

    private func isEnabled(_ action: BarAction) -> Bool {
        if case .undo = action { return !annotations.isEmpty }
        return true
    }

    private func drawGlyph(_ glyph: String, in rect: CGRect, color: NSColor, weight: NSFont.Weight) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: weight),
            .foregroundColor: color
        ]
        let size = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawColorDot(in rect: CGRect) {
        let dot = CGRect(x: rect.midX - 9, y: rect.midY - 9, width: 18, height: 18)
        currentColor.nsColor.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: dot)
        ring.lineWidth = 1
        ring.stroke()
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

    /// SF Symbol 是模板图，需要按当前图标色重新染色
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

    // MARK: - 弹层（形状 / 颜色，点击对应按钮后在工具条下方展开）

    private static let panelPadding: CGFloat = 8
    private static let panelButtonSize: CGFloat = 32
    private static let panelSpacing: CGFloat = 6
    private static let paletteDotSize: CGFloat = 24
    private static let paletteDotSpacing: CGFloat = 8
    private static let panelGap: CGFloat = 8

    private func panelFrame() -> CGRect? {
        guard let panel = openPanel else { return nil }
        let bar = barFrame()
        let size: CGSize
        switch panel {
        case .shapes:
            let count = CGFloat(Self.shapeTools.count)
            size = CGSize(
                width: count * Self.panelButtonSize + (count - 1) * Self.panelSpacing + Self.panelPadding * 2,
                height: Self.panelButtonSize + Self.panelPadding * 2
            )
        case .colors:
            let count = CGFloat(AnnotationColor.allCases.count)
            size = CGSize(
                width: count * Self.paletteDotSize + (count - 1) * Self.paletteDotSpacing + Self.panelPadding * 2,
                height: Self.paletteDotSize + Self.panelPadding * 2
            )
        }

        // 默认在工具条下方，屏幕底部放不下时翻到上方
        var originY = bar.maxY + Self.panelGap
        if originY + size.height > bounds.height - 8 {
            originY = bar.minY - size.height - Self.panelGap
        }
        let originX = min(max(8, bar.minX), max(8, bounds.width - size.width - 8))
        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    private func panelItemRect(at index: Int) -> CGRect? {
        guard let frame = panelFrame(), let panel = openPanel else { return nil }
        switch panel {
        case .shapes:
            return CGRect(
                x: frame.minX + Self.panelPadding + CGFloat(index) * (Self.panelButtonSize + Self.panelSpacing),
                y: frame.minY + Self.panelPadding,
                width: Self.panelButtonSize,
                height: Self.panelButtonSize
            )
        case .colors:
            return CGRect(
                x: frame.minX + Self.panelPadding + CGFloat(index) * (Self.paletteDotSize + Self.paletteDotSpacing),
                y: frame.midY - Self.paletteDotSize / 2,
                width: Self.paletteDotSize,
                height: Self.paletteDotSize
            )
        }
    }

    private func panelItemCount() -> Int {
        switch openPanel {
        case .shapes: return Self.shapeTools.count
        case .colors: return AnnotationColor.allCases.count
        case nil: return 0
        }
    }

    private func panelItemIndex(at point: CGPoint) -> Int? {
        guard let frame = panelFrame(), frame.contains(point) else { return nil }
        for index in 0..<panelItemCount() where panelItemRect(at: index)?.contains(point) == true {
            return index
        }
        return nil
    }

    private func drawPopupPanel() {
        guard let frame = panelFrame(), let panel = openPanel else { return }
        drawPopupBackground(frame, cornerRadius: 10)

        switch panel {
        case .shapes:
            for (index, kind) in Self.shapeTools.enumerated() {
                guard let rect = panelItemRect(at: index) else { continue }
                let isCurrent = activeTool == kind
                if isCurrent {
                    NSColor.systemBlue.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                } else if hoveredPanelIndex == index {
                    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                }
                drawGlyph(
                    symbol(for: kind),
                    in: rect,
                    color: isCurrent ? .white : Self.iconColor,
                    weight: .medium
                )
            }
        case .colors:
            for (index, color) in AnnotationColor.allCases.enumerated() {
                guard let dot = panelItemRect(at: index) else { continue }
                if hoveredPanelIndex == index {
                    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
                    NSBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3)).fill()
                }
                color.nsColor.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: 1, dy: 1)).fill()
                if currentColor == color {
                    NSColor.systemBlue.setStroke()
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                    ring.lineWidth = 2
                    ring.stroke()
                } else {
                    NSColor.black.withAlphaComponent(0.2).setStroke()
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                    ring.lineWidth = 1
                    ring.stroke()
                }
            }
        }
    }

    /// 工具激活后在工具条上方提示下一步操作，避免用户只看到高亮却不知道要拖拽
    private func drawToolHint() {
        // 面板展开时本身已是线索，再叠一层提示会互相遮挡
        guard openPanel == nil, let kind = activeTool else { return }
        let text = hintText(for: kind)
        let bar = barFrame()
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: textAttributes)
        let padding = CGSize(width: 8, height: 4)
        let rect = CGRect(
            x: bar.midX - (size.width + padding.width * 2) / 2,
            y: bar.minY - size.height - padding.height * 2 - 8,
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )
        guard rect.minY >= 0 else { return }

        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        text.draw(
            at: CGPoint(x: rect.minX + padding.width, y: rect.minY + padding.height),
            withAttributes: textAttributes
        )
    }

    private func hintText(for kind: Annotation.Kind) -> String {
        switch kind {
        case .text: return "点击选区内位置后输入文字"
        case .number: return "点击选区内位置放置序号"
        default: return "在选区内拖动绘制"
        }
    }

    // MARK: - 悬停提示

    /// 自绘按钮没有文字标签，靠系统 tooltip 说明用途与快捷键
    private func refreshToolTips() {
        removeAllToolTips()
        guard completedRect != nil else { return }
        for index in barActions.indices {
            addToolTip(barItemRect(at: index), owner: self, userData: nil)
        }
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let action = barAction(at: point) else { return "" }
        switch action {
        case .shapes:
            return "形状（当前：\(lastShape.displayName)）\n点击选择矩形 / 椭圆 / 直线 / 箭头"
        case .tool(let kind):
            return "\(kind.displayName)（\(kind.shortcut)）\n\(hintText(for: kind))"
        case .colors:
            return "颜色\n点击在工具条下方展开调色板"
        case .undo:
            return annotations.isEmpty ? "撤销：暂无可撤销的标注" : "撤销（⌘Z）"
        case .longShot: return "长截图\n点击后按提示滚动页面，最后点「完成」输出长图"
        case .ocr: return "识别文字\n把选区内的文字提取为可编辑文本"
        case .save: return "保存为 PNG（⌘S）"
        case .pin: return "贴到屏幕上"
        case .cancel: return "取消截图（Esc）"
        case .confirm: return "完成并复制到剪贴板（Enter）"
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
            drawPopupPanel()
            drawToolHint()
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
        let point = convert(event.locationInWindow, from: nil)

        // 工具栏与弹层的悬停高亮
        if completedRect != nil {
            updateHover(at: point)
            return
        }

        guard !state.isDragging, pressedWindowRect == nil else { return }
        hoveredWindowRect = detectedWindowRect(at: point)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredBarIndex != nil || hoveredPanelIndex != nil else { return }
        hoveredBarIndex = nil
        hoveredPanelIndex = nil
        needsDisplay = true
    }

    /// 只在悬停目标变化时重绘，避免高频 mouseMoved 反复重画整屏
    private func updateHover(at point: CGPoint) {
        var barIndex: Int?
        if barFrame().insetBy(dx: -6, dy: -6).contains(point) {
            for index in barActions.indices where barItemRect(at: index).contains(point) {
                barIndex = index
                break
            }
        }
        let panelIndex = panelItemIndex(at: point)
        guard barIndex != hoveredBarIndex || panelIndex != hoveredPanelIndex else { return }
        hoveredBarIndex = barIndex
        hoveredPanelIndex = panelIndex
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)

        // 文字输入进行中，点别处先提交
        if textInput != nil {
            commitTextInput()
        }

        // 弹层优先；点面板外顺手收起
        if let frame = panelFrame(), frame.insetBy(dx: -4, dy: -4).contains(point) {
            if let index = panelItemIndex(at: point) {
                selectPanelItem(index)
            }
            return
        }
        if openPanel != nil {
            openPanel = nil
            needsDisplay = true
        }

        // 底栏优先；工具栏容器（含 padding 与 gap）一并吞掉，避免穿透到选区内部误确认
        if let action = barAction(at: point) {
            perform(action)
            return
        }
        if completedRect != nil, barFrame().insetBy(dx: -6, dy: -6).contains(point) {
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
        // 工具栏出现或位置变化后，光标与悬停提示需要重新登记
        defer {
            window?.invalidateCursorRects(for: self)
            refreshToolTips()
        }
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
        // 面板开关会改变可点区域，光标登记需要同步
        defer {
            window?.invalidateCursorRects(for: self)
            hoveredPanelIndex = nil
        }

        switch action {
        case .shapes:
            openPanel = (openPanel == .shapes) ? nil : .shapes
            needsDisplay = true
        case .tool(let kind):
            activate(kind)
            openPanel = nil
            needsDisplay = true
        case .colors:
            openPanel = (openPanel == .colors) ? nil : .colors
            needsDisplay = true
        case .undo:
            guard !annotations.isEmpty else { return }
            undo()
        case .longShot:
            if let selection = completedRect ?? (state.isUsable ? state.rect : nil) {
                onLongShot?(selection, annotations)
            }
        case .ocr:
            if let selection = completedRect ?? (state.isUsable ? state.rect : nil) {
                onOCR?(selection, annotations)
            }
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

    /// 切换标注工具；形状类工具关闭后，形状按钮仍回显它
    private func activate(_ kind: Annotation.Kind) {
        activeTool = (activeTool == kind) ? nil : kind
        if Self.shapeTools.contains(kind) {
            lastShape = kind
        }
        NSLog("iCut: 标注工具 = \(activeTool?.displayName ?? "无")")
    }

    /// 弹层点击：形状面板选工具，颜色面板选色
    private func selectPanelItem(_ index: Int) {
        switch openPanel {
        case .shapes:
            guard Self.shapeTools.indices.contains(index) else { return }
            activate(Self.shapeTools[index])
        case .colors:
            guard AnnotationColor.allCases.indices.contains(index) else { return }
            currentColor = AnnotationColor.allCases[index]
        case nil:
            return
        }
        openPanel = nil
        hoveredPanelIndex = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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
            activate(tool)
            openPanel = nil
            needsDisplay = true
            return
        }

        switch keyCode {
        case kVK_Escape:
            // 先收面板，再退工具，最后才退出截图
            if openPanel != nil {
                openPanel = nil
                needsDisplay = true
            } else if activeTool != nil {
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
