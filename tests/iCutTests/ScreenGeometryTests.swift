import CoreGraphics

/// ScreenGeometry 的行为约定：AppKit/Quartz 坐标翻转、像素取整、缩放锚点与尺寸钳制。
func runScreenGeometryTests() {
    // 主屏：AppKit 与 Quartz 重合
    let main = ScreenGeometry.quartzRect(
        fromAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
        primaryHeight: 900
    )
    expectEqual(main, CGRect(x: 0, y: 0, width: 1440, height: 900), "主屏 Quartz 矩形不变")

    // 副屏在主屏上方：Quartz y 为负
    let above = ScreenGeometry.quartzRect(
        fromAppKit: CGRect(x: 0, y: 900, width: 1920, height: 1080),
        primaryHeight: 900
    )
    expectEqual(above, CGRect(x: 0, y: -1080, width: 1920, height: 1080), "上方副屏 Quartz y 为负")

    // 副屏在左侧
    let left = ScreenGeometry.quartzRect(
        fromAppKit: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        primaryHeight: 900
    )
    expectEqual(left, CGRect(x: -1920, y: -180, width: 1920, height: 1080), "左侧副屏 Quartz 偏移")

    // 像素换算
    let pixel = ScreenGeometry.pixelRect(
        fromPoint: CGRect(x: 10, y: 20, width: 100, height: 50),
        scale: 2
    )
    expectEqual(pixel, CGRect(x: 20, y: 40, width: 200, height: 100), "2x 像素换算")

    // 取整：0.5pt 起点、10.3pt 宽度 @2x → 原点向下取整、终点向上取整
    let rounded = ScreenGeometry.pixelRect(
        fromPoint: CGRect(x: 0.5, y: 0.5, width: 10.3, height: 10.3),
        scale: 2
    )
    expectEqual(rounded.minX, 1, "像素原点向下取整")
    expectEqual(rounded.maxX, 22, "像素终点向上取整")

    // 缩放锚点：光标在窗口中心，放大后中心不动
    let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
    let center = CGPoint(x: 200, y: 150)
    let zoomed = ScreenGeometry.zoomedFrame(
        current: frame,
        cursor: center,
        factor: 2,
        minSide: 40,
        maxSide: 4000
    )
    expectEqual(zoomed.size, CGSize(width: 400, height: 200), "放大后尺寸")
    expectEqual(zoomed.origin, CGPoint(x: 0, y: 50), "中心锚点保持不动")

    // 光标在左上角：放大后 origin 不变
    let corner = ScreenGeometry.zoomedFrame(
        current: frame,
        cursor: CGPoint(x: 100, y: 100),
        factor: 2,
        minSide: 40,
        maxSide: 4000
    )
    expectEqual(corner.origin, CGPoint(x: 100, y: 100), "角锚点保持不动")

    // 尺寸钳制
    let shrunk = ScreenGeometry.zoomedFrame(
        current: frame,
        cursor: center,
        factor: 0.001,
        minSide: 40,
        maxSide: 4000
    )
    expectClose(shrunk.width, 40, "缩到下限被钳制")

    let grown = ScreenGeometry.zoomedFrame(
        current: frame,
        cursor: center,
        factor: 1000,
        minSide: 40,
        maxSide: 4000
    )
    expectClose(grown.width, 4000, "放大到上限被钳制")

    // 非法输入不改变窗口
    let invalid = ScreenGeometry.zoomedFrame(
        current: frame,
        cursor: center,
        factor: .nan,
        minSide: 40,
        maxSide: 4000
    )
    expectEqual(invalid, frame, "非法缩放因子保持原 frame")
}
