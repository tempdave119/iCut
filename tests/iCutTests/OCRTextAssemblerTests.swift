import CoreGraphics

/// OCRTextAssembler 的行为约定：Vision 的归一化坐标原点在左下，拼接顺序是先上后下、同行左到右。
func runOCRTextAssemblerTests() {
    let lines = [
        RecognizedLine(boundingBox: CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.05), text: "第二行右"),
        RecognizedLine(boundingBox: CGRect(x: 0.05, y: 0.80, width: 0.30, height: 0.05), text: "第一行左"),
        RecognizedLine(boundingBox: CGRect(x: 0.50, y: 0.805, width: 0.30, height: 0.05), text: "第一行右"),
        RecognizedLine(boundingBox: CGRect(x: 0.05, y: 0.10, width: 0.30, height: 0.05), text: "第二行左")
    ]

    expectEqual(
        OCRTextAssembler.merge(lines),
        "第一行左\n第一行右\n第二行左\n第二行右",
        "按上到下、左到右拼接"
    )
    expectEqual(OCRTextAssembler.merge([]), "", "空结果拼成空串")
}
