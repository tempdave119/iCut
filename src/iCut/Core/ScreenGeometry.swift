import CoreGraphics

/// 坐标换算与缩放锚点的纯函数集合。
/// 多屏与 Retina 的换算只在这里做，避免散落在窗口代码里各写一套。
enum ScreenGeometry {
    /// AppKit 全局坐标（原点在主屏左下）转 Quartz 全局坐标（原点在主屏左上）
    static func quartzRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 点矩形转像素矩形并取整，避免裁切边缘出现半像素
    static func pixelRect(fromPoint rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
    }

    /// 以光标为锚点缩放窗口：保持光标下的图像相对位置不动，尺寸限制在 [minSide, maxSide]
    static func zoomedFrame(
        current: CGRect,
        cursor: CGPoint,
        factor: CGFloat,
        minSide: CGFloat,
        maxSide: CGFloat
    ) -> CGRect {
        guard current.width > 0, current.height > 0, factor.isFinite, factor > 0 else {
            return current
        }

        let newWidth = max(minSide, min(current.width * factor, maxSide))
        let newHeight = newWidth * current.height / current.width
        guard newHeight.isFinite, newHeight > 0 else { return current }

        let u = (cursor.x - current.minX) / current.width
        let v = (cursor.y - current.minY) / current.height
        return CGRect(
            x: cursor.x - u * newWidth,
            y: cursor.y - v * newHeight,
            width: newWidth,
            height: newHeight
        )
    }
}
