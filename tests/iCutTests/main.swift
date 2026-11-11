import CoreGraphics

/// 自建测试入口：本机 SwiftPM 不可用，测试用 swiftc 编译成可执行文件运行。
/// 断言失败非零退出，供 CI 与本地共用。
var failures = 0
var assertions = 0

func expect(_ condition: Bool, _ message: String, line: Int = #line) {
    assertions += 1
    if !condition {
        failures += 1
        print("FAIL: \(message)（main.swift:\(line)）")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    assertions += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(message) — 期望 \(expected)，实际 \(actual)（main.swift:\(line)）")
    }
}

func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ message: String, tolerance: CGFloat = 0.0001, line: Int = #line) {
    assertions += 1
    if abs(actual - expected) > tolerance {
        failures += 1
        print("FAIL: \(message) — 期望 \(expected)，实际 \(actual)（main.swift:\(line)）")
    }
}

runSelectionStateTests()
runScreenGeometryTests()
runHotKeyStoreTests()
runFileNameTemplateTests()
runOCRTextAssemblerTests()
runAutoSaverTests()
runSettingsMigrationTests()
runRollingStitcherTests()
runStitchAccumulatorTests()
runStickyHeaderStitchingTests()
runScrollbarStitchingTests()

print("")
if failures == 0 {
    print("全部通过：\(assertions) 个断言")
    exit(0)
} else {
    print("失败 \(failures) / \(assertions) 个断言")
    exit(1)
}
