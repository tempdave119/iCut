import Foundation

/// FileNameTemplate 的行为约定：占位符替换、非法字符替换、空模板回落。
func runFileNameTemplateTests() {
    var components = DateComponents()
    components.year = 2026
    components.month = 11
    components.day = 11
    components.hour = 22
    components.minute = 5
    components.second = 31
    let date = Calendar(identifier: .gregorian).date(from: components)!

    expectEqual(
        FileNameTemplate.render(template: FileNameTemplate.defaultTemplate, date: date),
        "iCut-261111220531",
        "默认模板渲染为 iCut-yymmddhhmmss"
    )
    expectEqual(
        FileNameTemplate.render(template: "shot-{timestamp}", date: date),
        "shot-261111220531",
        "{timestamp} 渲染为 yyMMddHHmmss"
    )
    expectEqual(
        FileNameTemplate.render(template: "iCut {date} {time}", date: date),
        "iCut 2026-11-11 22.05.31",
        "显式 date+time 模板仍按原格式渲染"
    )
    expectEqual(
        FileNameTemplate.render(template: "截图 {datetime}", date: date),
        "截图 2026-11-11 22.05.31",
        "{datetime} 渲染"
    )
    expectEqual(
        FileNameTemplate.render(template: "shot-{seq}", date: date, sequence: 3),
        "shot-3",
        "{seq} 渲染序号"
    )
    expectEqual(
        FileNameTemplate.render(template: "shot-{seq}", date: date),
        "shot",
        "未提供序号时去掉占位符与残留分隔符"
    )
    expectEqual(
        FileNameTemplate.render(template: "a/b:c", date: date),
        "a-b-c",
        "非法字符替换为 -"
    )
    expectEqual(
        FileNameTemplate.render(template: "   ", date: date),
        "iCut-261111220531",
        "空白模板回落到默认模板"
    )
    expectEqual(
        FileNameTemplate.render(template: "///", date: date),
        "iCut",
        "模板清洗后为空时回落到 iCut"
    )
    expectEqual(
        FileNameTemplate.render(template: "iCut {date} {time}", date: date, sequence: 2),
        "iCut 2026-11-11 22.05.31",
        "模板里没有 {seq} 时序号不影响结果"
    )
}
