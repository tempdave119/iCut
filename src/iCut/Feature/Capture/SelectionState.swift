import CoreGraphics

/// 选区状态机：只算坐标与判定，不碰 UI，便于单测。
/// 坐标使用屏内局部坐标，原点左上（与覆盖层视图的 flipped 坐标系一致）。
struct SelectionState {
    /// 选区任一边小于此值视为没有有效选区
    static let minimumSide: CGFloat = 4

    private(set) var anchor: CGPoint?
    private(set) var current: CGPoint?

    var isDragging: Bool { anchor != nil }

    /// 归一化选区：反向拖拽时自动换算出正矩形
    var rect: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }

    var isUsable: Bool {
        guard let rect else { return false }
        return rect.width >= Self.minimumSide && rect.height >= Self.minimumSide
    }

    mutating func begin(at point: CGPoint) {
        anchor = point
        current = point
    }

    mutating func drag(to point: CGPoint) {
        guard anchor != nil else { return }
        current = point
    }

    mutating func reset() {
        anchor = nil
        current = nil
    }
}
