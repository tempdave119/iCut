import CryptoKit
import Foundation
import Security

/// 剪贴板历史的加密入口：AES-256-GCM；主密钥存钥匙串，进程内缓存，退出不落盘。
/// 加解密纯函数与密钥来源分开：单测只验证算法往返，不触碰钥匙串。
enum ClipboardCrypto {
    private static let service = "com.icut.app"
    private static let account = "clipboard.masterKey"

    private static var cachedKey: SymmetricKey?
    private static let lock = NSLock()

    // MARK: - 纯函数（可单测）

    static func randomKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func seal(_ data: Data, using key: SymmetricKey) -> Data? {
        do {
            // combined 把 nonce、密文与 tag 拼在一起，落盘只需要一个二进制块
            return try AES.GCM.seal(data, using: key).combined
        } catch {
            NSLog("iCut: 剪贴板历史加密失败 — \(error)")
            return nil
        }
    }

    static func open(_ data: Data, using key: SymmetricKey) -> Data? {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key)
        } catch {
            NSLog("iCut: 剪贴板历史解密失败 — \(error)")
            return nil
        }
    }

    // MARK: - 主密钥

    /// 读取失败返回 nil：调用方据此暂停记录，绝不静默降级为明文。
    /// 钥匙串访问不放在锁内，避免授权弹窗/钥匙串变慢时主线程一直等锁。
    static var masterKey: SymmetricKey? {
        lock.lock()
        if let cachedKey {
            lock.unlock()
            return cachedKey
        }
        lock.unlock()

        guard let key = loadOrCreateKey() else { return nil }
        lock.lock()
        if cachedKey == nil { cachedKey = key }
        let resolved = cachedKey
        lock.unlock()
        return resolved
    }

    /// 重建密钥 = 删除旧条目 + 生成新密钥；历史数据由调用方负责清空。
    @discardableResult
    static func regenerateKey() -> SymmetricKey? {
        lock.lock()
        cachedKey = nil
        lock.unlock()

        deleteKey()
        guard let key = loadOrCreateKey() else { return nil }
        lock.lock()
        cachedKey = key
        lock.unlock()
        return key
    }

    static func resetCache() {
        lock.lock()
        cachedKey = nil
        lock.unlock()
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// 查询时必须显式要数据：默认只回属性，拿不到密钥字节。
    private static func copyQuery() -> [String: Any] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static func loadOrCreateKey() -> SymmetricKey? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(copyQuery() as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        if status != errSecItemNotFound {
            NSLog("iCut: 读取剪贴板历史主密钥失败，status=\(status)")
            return nil
        }

        var secret = Data(count: 32)
        let randomStatus = secret.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard randomStatus == errSecSuccess else {
            NSLog("iCut: 生成剪贴板历史主密钥失败，status=\(randomStatus)")
            return nil
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = secret
        // 只在本机、开机解锁后可用：不随备份迁移，换机后历史本来也无法解密
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            NSLog("iCut: 写入剪贴板历史主密钥失败，status=\(addStatus)")
            return nil
        }
        return SymmetricKey(data: secret)
    }

    private static func deleteKey() {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("iCut: 删除剪贴板历史主密钥失败，status=\(status)")
        }
    }
}
