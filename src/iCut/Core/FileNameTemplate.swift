import Foundation

/// 文件名模板：只认 `{timestamp}` `{date}` `{time}` `{datetime}` `{seq}` 五个占位符，其余字符原样保留。
/// 把模板与日期格式化拆开，避免用户写的普通字母被 DateFormatter 当成格式符解析。
enum FileNameTemplate {
    /// 默认 `iCut-yymmddhhmmss`，例：iCut-261111220531
    static let defaultTemplate = "iCut-{timestamp}"

    /// 生成不含扩展名的文件名；非法字符替换为 "-"，结果为空时回落到 "iCut"。
    static func render(template: String, date: Date = Date(), sequence: Int? = nil) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? defaultTemplate : trimmed

        var text = source
        text = text.replacingOccurrences(of: "{timestamp}", with: format("yyMMddHHmmss", date))
        text = text.replacingOccurrences(of: "{datetime}", with: format("yyyy-MM-dd HH.mm.ss", date))
        text = text.replacingOccurrences(of: "{date}", with: format("yyyy-MM-dd", date))
        text = text.replacingOccurrences(of: "{time}", with: format("HH.mm.ss", date))
        // 没给序号时把占位符直接去掉，避免文件名里残留花括号
        text = text.replacingOccurrences(of: "{seq}", with: sequence.map(String.init) ?? "")

        let sanitized = sanitize(text)
        return sanitized.isEmpty ? "iCut" : sanitized
    }

    private static func format(_ pattern: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// 把这些字符换成 "-"：路径分隔符与 Windows/macOS 都不接受的文件名字符
    private static let illegalCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")

    private static func sanitize(_ text: String) -> String {
        text.components(separatedBy: illegalCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }
}
