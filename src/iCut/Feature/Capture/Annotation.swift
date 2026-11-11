import CoreGraphics

/// 一条标注。坐标统一用屏内视图坐标（原点左上）。
struct Annotation {
    enum Kind: CaseIterable {
        case rectangle
        case ellipse
        case arrow
        case line
        case freehand
        case text
        case mosaic
        case number

        var displayName: String {
            switch self {
            case .rectangle: return "矩形"
            case .ellipse: return "椭圆"
            case .arrow: return "箭头"
            case .line: return "直线"
            case .freehand: return "画笔"
            case .text: return "文字"
            case .mosaic: return "马赛克"
            case .number: return "序号"
            }
        }

        var shortcut: String {
            switch self {
            case .rectangle: return "R"
            case .ellipse: return "O"
            case .arrow: return "A"
            case .line: return "L"
            case .freehand: return "P"
            case .text: return "T"
            case .mosaic: return "M"
            case .number: return "N"
            }
        }
    }

    let kind: Kind
    /// 矩形/椭圆/线段/箭头为 [起点, 终点]；画笔为轨迹点；文字与序号为单点
    var points: [CGPoint]
    var text: String?
    var number: Int?

    /// 标注覆盖的矩形，用于绘制裁剪与预览
    var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        if points.count == 1 {
            return CGRect(x: first.x - 16, y: first.y - 16, width: 32, height: 32)
        }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
