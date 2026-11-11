import AppKit
import Vision

/// 一行识别结果；boundingBox 是 Vision 的归一化坐标（原点左下）。
struct RecognizedLine {
    let boundingBox: CGRect
    let text: String
}

/// 把识别结果按阅读顺序拼成文本：先上后下，同一高度内左到右。
enum OCRTextAssembler {
    /// 同一行允许 1% 的高度误差，避免中文与英文基线差导致的换行错位
    private static let sameLineTolerance: CGFloat = 0.01

    static func merge(_ lines: [RecognizedLine]) -> String {
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > sameLineTolerance {
                return lhs.boundingBox.maxY > rhs.boundingBox.maxY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return sorted.map(\.text).joined(separator: "\n")
    }
}

/// 用系统 Vision 在本地做文字识别：不联网、不需要额外权限、无三方依赖。
enum TextRecognizer {
    enum Failure: LocalizedError {
        case recognitionFailed(String)
        case noText

        var errorDescription: String? {
            switch self {
            case .recognitionFailed(let reason): return "识别失败：\(reason)"
            case .noText: return "未识别到文字"
            }
        }
    }

    /// 回调固定回到主线程；识别在后台队列执行，避免大图卡住界面。
    static func recognize(image: CGImage, completion: @escaping (Result<String, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // 语言包在部分系统上可能缺失，只申请系统实际支持的语言
            let preferred = ["zh-Hans", "en-US"]
            if let supported = try? request.supportedRecognitionLanguages() {
                let available = preferred.filter(supported.contains)
                if !available.isEmpty {
                    request.recognitionLanguages = available
                }
            }

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                let reason = error.localizedDescription
                DispatchQueue.main.async { completion(.failure(.recognitionFailed(reason))) }
                return
            }

            let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedLine(boundingBox: observation.boundingBox, text: candidate.string)
            }
            let text = OCRTextAssembler.merge(lines)

            DispatchQueue.main.async {
                completion(text.isEmpty ? .failure(.noText) : .success(text))
            }
        }
    }
}
