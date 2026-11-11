import CoreGraphics

/// SelectionState 的行为约定：反向拖拽归一化、4pt 最小尺寸、reset 清空。
func runSelectionStateTests() {
    var state = SelectionState()
    expect(state.rect == nil, "初始状态 rect 应为 nil")
    expect(!state.isUsable, "初始状态不应有有效选区")

    state.begin(at: CGPoint(x: 10, y: 20))
    state.drag(to: CGPoint(x: 110, y: 70))
    expectClose(state.rect?.width ?? 0, 100, "正向拖拽宽度")
    expectClose(state.rect?.height ?? 0, 50, "正向拖拽高度")
    expect(state.isUsable, "100x50 应为有效选区")

    // 反向拖拽必须归一化成正矩形，否则裁切会得到空图
    state = SelectionState()
    state.begin(at: CGPoint(x: 110, y: 70))
    state.drag(to: CGPoint(x: 10, y: 20))
    expectClose(state.rect?.minX ?? -1, 10, "反向拖拽 minX 归一化")
    expectClose(state.rect?.minY ?? -1, 20, "反向拖拽 minY 归一化")

    // 最小尺寸边界
    state = SelectionState()
    state.begin(at: CGPoint(x: 0, y: 0))
    state.drag(to: CGPoint(x: 3.9, y: 10))
    expect(!state.isUsable, "宽 3.9pt 不应视为有效选区")

    state = SelectionState()
    state.begin(at: CGPoint(x: 0, y: 0))
    state.drag(to: CGPoint(x: 4, y: 10))
    expect(state.isUsable, "宽恰好 4pt 应为有效选区")

    // 未 begin 时 drag 不应产生选区
    state = SelectionState()
    state.drag(to: CGPoint(x: 50, y: 50))
    expect(state.rect == nil, "未 begin 时 drag 不产生选区")

    state.begin(at: CGPoint(x: 0, y: 0))
    state.drag(to: CGPoint(x: 60, y: 60))
    state.reset()
    expect(state.rect == nil, "reset 后 rect 应为 nil")
}
