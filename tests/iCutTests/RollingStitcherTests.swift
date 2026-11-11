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
        40,
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
        100,
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
        40,
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
