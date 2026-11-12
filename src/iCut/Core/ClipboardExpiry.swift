import Foundation

/// 单条记录的过期提示：纯函数，便于单测与统一文案。
enum ClipboardExpiry {
    /// retention 为 nil 表示永久保留；收藏条目跳过时间淘汰，直接显示「永久保留」。
    static func text(
        createdAt: Date,
        isPinned: Bool,
        retention: TimeInterval?,
        now: Date = Date()
    ) -> String {
        if isPinned { return "永久保留" }
        guard let retention else { return "不过期" }

        let remaining = createdAt.addingTimeInterval(retention).timeIntervalSince(now)
        if remaining <= 0 { return "已过期" }
        if remaining >= 86_400 {
            return "\(Int(remaining / 86_400)) 天后过期"
        }
        if remaining >= 3_600 {
            return "\(Int(remaining / 3_600)) 小时后过期"
        }
        return "\(max(1, Int(remaining / 60))) 分钟后过期"
    }
}
