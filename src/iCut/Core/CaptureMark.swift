import Foundation

/// 截图写入剪贴板后的来源标记：用 changeCount 关联，避免布尔标记错位。
struct CaptureMark {
    private var expectedChangeCount: Int?

    mutating func note(changeCount: Int) {
        expectedChangeCount = changeCount
    }

    mutating func consume(changeCount: Int) -> Bool {
        guard expectedChangeCount == changeCount else { return false }
        expectedChangeCount = nil
        return true
    }

    mutating func reset() {
        expectedChangeCount = nil
    }
}
