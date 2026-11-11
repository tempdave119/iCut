import CoreGraphics

/// 长截图拼接的行为约定：重叠识别、无重叠、未滚动、个别行变化、合成顺序与高度上限。
func runRollingStitcherTests() {
    let width = 40

    guard let first = makeRowsImage(from: 0, count: 100, width: width),
          let second = makeRowsImage(from: 60, count: 100, width: width) else {
        expect(false, "构造测试图失败")
        return
    }
    let firstHashes = RollingStitcher.rowHashes(of: first)
    expectEqual(firstHashes.count, 100, "行指纹数量等于图像高度")

    expectEqual(
        RollingStitcher.findOverlap(existing: firstHashes, incoming: RollingStitcher.rowHashes(of: second), minOverlap: 40),
        RollingStitcher.Overlap(skipRows: 0, overlapRows: 40),
        "相邻帧重叠 40 行"
    )

    guard let far = makeRowsImage(from: 200, count: 50, width: width) else {
        expect(false, "构造测试图失败")
        return
    }
    expect(
        RollingStitcher.findOverlap(
            existing: firstHashes,
            incoming: RollingStitcher.rowHashes(of: far),
            minOverlap: 40
        ) == nil,
        "没有重叠时应返回 nil"
    )

    expectEqual(
        RollingStitcher.findOverlap(existing: firstHashes, incoming: firstHashes, minOverlap: 40),
        RollingStitcher.Overlap(skipRows: 0, overlapRows: 100),
        "画面未滚动时重叠等于帧高"
    )

    guard let corrupted = makeRowsImage(from: 60, count: 100, width: width, corruptRows: [10, 11]) else {
        expect(false, "构造测试图失败")
        return
    }
    expectEqual(
        RollingStitcher.findOverlap(
            existing: firstHashes,
            incoming: RollingStitcher.rowHashes(of: corrupted),
            minOverlap: 40
        ),
        RollingStitcher.Overlap(skipRows: 0, overlapRows: 40),
        "个别行变化（光标闪烁）仍能匹配到重叠"
    )
}

func runStitchAccumulatorTests() {
    let width = 40

    guard let first = makeRowsImage(from: 0, count: 100, width: width),
          let second = makeRowsImage(from: 60, count: 100, width: width),
          let third = makeRowsImage(from: 120, count: 100, width: width),
          let expected = makeRowsImage(from: 0, count: 220, width: width) else {
        expect(false, "构造测试图失败")
        return
    }

    let accumulator = StitchAccumulator(maxHeight: 20000)
    expectEqual(accumulator.append(first), .appended(addedRows: 100), "首帧全量加入")
    expectEqual(accumulator.append(second), .appended(addedRows: 60), "第二帧只追加 60 行")
    expectEqual(accumulator.append(third), .appended(addedRows: 60), "第三帧只追加 60 行")
    expectEqual(accumulator.height, 220, "累计高度")

    guard let stitched = accumulator.makeImage() else {
        expect(false, "合成失败")
        return
    }
    expectEqual(stitched.width, width, "合成宽度")
    expectEqual(stitched.height, 220, "合成高度")
    expectEqual(
        RollingStitcher.rowHashes(of: stitched),
        RollingStitcher.rowHashes(of: expected),
        "合成内容与整页逐行一致（含顺序）"
    )

    expectEqual(accumulator.append(third), .unchanged("画面未滚动"), "重复帧不追加")

    let limited = StitchAccumulator(maxHeight: 120)
    expectEqual(limited.append(first), .appended(addedRows: 100), "上限内首帧正常加入")
    expectEqual(limited.append(second), .unchanged("已达高度上限"), "超出上限拒绝追加")
    expectEqual(limited.height, 100, "超限后高度不变")
}

/// 页面顶部有粘性导航栏时：头部只保留一份，正文连续拼接。
func runStickyHeaderStitchingTests() {
    let width = 40
    let headerHeight = 30

    guard let header = makeRowsImage(from: 900, count: headerHeight, width: width),
          let body1 = makeRowsImage(from: 0, count: 100, width: width),
          let body2 = makeRowsImage(from: 60, count: 100, width: width),
          let body3 = makeRowsImage(from: 120, count: 100, width: width),
          let frame1 = makeFrame(header: header, body: body1),
          let frame2 = makeFrame(header: header, body: body2),
          let frame3 = makeFrame(header: header, body: body3),
          let expectedBody = makeRowsImage(from: 0, count: 220, width: width),
          let expected = makeFrame(header: header, body: expectedBody) else {
        expect(false, "构造粘性头部测试图失败")
        return
    }

    expectEqual(
        RollingStitcher.findOverlap(
            existing: RollingStitcher.rowHashes(of: frame1),
            incoming: RollingStitcher.rowHashes(of: frame2),
            minOverlap: 40
        ),
        RollingStitcher.Overlap(skipRows: headerHeight, overlapRows: 40),
        "粘性头部应被识别为跳过的行"
    )

    let accumulator = StitchAccumulator(maxHeight: 20000)
    expectEqual(accumulator.append(frame1), .appended(addedRows: 130), "首帧含头部全量加入")
    expectEqual(accumulator.append(frame2), .appended(addedRows: 60), "第二帧丢掉头部后追加 60 行")
    expectEqual(accumulator.append(frame3), .appended(addedRows: 60), "第三帧同理")
    expectEqual(accumulator.height, 250, "累计高度 = 头部 30 + 正文 220")

    guard let stitched = accumulator.makeImage() else {
        expect(false, "合成失败")
        return
    }
    expectEqual(
        RollingStitcher.rowHashes(of: stitched),
        RollingStitcher.rowHashes(of: expected),
        "粘性头部只出现一次，正文连续"
    )
}

/// 页面右侧有滚动条时：thumb 位置每帧不同，不能影响重叠识别。
func runScrollbarStitchingTests() {
    let barWidth = 15
    let width = 220
    let bodyWidth = width - barWidth

    guard let body1 = makeRowsImage(from: 0, count: 100, width: bodyWidth),
          let body2 = makeRowsImage(from: 60, count: 100, width: bodyWidth),
          let frame1 = makeFrameWithScrollbar(body: body1, barWidth: barWidth, thumbRows: 60..<90, width: width),
          let frame2 = makeFrameWithScrollbar(body: body2, barWidth: barWidth, thumbRows: 0..<20, width: width) else {
        expect(false, "构造滚动条测试图失败")
        return
    }

    expectEqual(
        RollingStitcher.findOverlap(
            existing: RollingStitcher.rowHashes(of: frame1),
            incoming: RollingStitcher.rowHashes(of: frame2),
            minOverlap: 40
        ),
        RollingStitcher.Overlap(skipRows: 0, overlapRows: 40),
        "右侧滚动条位置变化不应影响重叠识别"
    )
}

/// 把正文和右侧滚动条拼成一张帧图；thumbRows 用顶行坐标
private func makeFrameWithScrollbar(body: CGImage, barWidth: Int, thumbRows: Range<Int>, width: Int) -> CGImage? {
    let height = body.height
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    context.draw(body, in: CGRect(x: 0, y: 0, width: CGFloat(body.width), height: CGFloat(height)))

    let barX = CGFloat(width - barWidth)
    context.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
    context.fill(CGRect(x: barX, y: 0, width: CGFloat(barWidth), height: CGFloat(height)))
    context.setFillColor(CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1))
    context.fill(
        CGRect(
            x: barX,
            y: CGFloat(height - thumbRows.upperBound),
            width: CGFloat(barWidth),
            height: CGFloat(thumbRows.count)
        )
    )
    return context.makeImage()
}

/// 把头部和正文上下拼成一张帧图（头部在顶部）
private func makeFrame(header: CGImage?, body: CGImage) -> CGImage? {
    let width = body.width
    let headerHeight = header?.height ?? 0
    let height = headerHeight + body.height
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    var y = CGFloat(height)
    if let header {
        y -= CGFloat(header.height)
        context.draw(header, in: CGRect(x: 0, y: y, width: CGFloat(width), height: CGFloat(header.height)))
    }
    y -= CGFloat(body.height)
    context.draw(body, in: CGRect(x: 0, y: y, width: CGFloat(width), height: CGFloat(body.height)))
    return context.makeImage()
}

/// 逐行渐变测试图：每行颜色由行号决定，行与行差异明显，便于验证重叠与拼接顺序
private func makeRowsImage(from start: Int, count: Int, width: Int, corruptRows: Set<Int> = []) -> CGImage? {
    guard width > 0, count > 0 else { return nil }
    let bytesPerRow = width * 4
    var data = [UInt8](repeating: 255, count: bytesPerRow * count)

    for row in 0..<count {
        let index = start + row
        let corrupt = corruptRows.contains(row)
        let red = UInt8(index % 251)
        let green = UInt8((index * 7 + 40) % 256)
        let blue = UInt8((index * 13 + 90) % 256)
        for x in 0..<width {
            let offset = row * bytesPerRow + x * 4
            data[offset] = corrupt ? 255 - red : red
            data[offset + 1] = corrupt ? 255 - green : green
            data[offset + 2] = corrupt ? 255 - blue : blue
            data[offset + 3] = 255
        }
    }

    return data.withUnsafeMutableBytes { raw -> CGImage? in
        guard let context = CGContext(
            data: raw.baseAddress,
            width: width,
            height: count,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        return context.makeImage()
    }
}
