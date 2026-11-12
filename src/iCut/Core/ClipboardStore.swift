import AppKit
import CryptoKit
import Foundation

/// 剪贴板历史仓库：内存数组 + 加密索引文件；所有读写走串行队列。
/// 索引在 Application Support（含备份），图片密文在 Caches（可被系统清理）。
final class ClipboardStore {
    struct ClipItem: Codable, Equatable {
        enum Kind: String, Codable {
            case text
            case image
            case fileURLs
        }

        let id: UUID
        var kind: Kind
        var createdAt: Date
        var text: String?
        var rtfData: Data?
        var imageFile: String?
        var thumbnailPNG: Data?
        var filePaths: [String]?
        var isPinned: Bool
        var hash: Data
        var byteCount: Int
        var isTruncated: Bool
        /// P1 起记录：图片点尺寸比例与是否来自 iCut 截图；旧索引没有这两个字段。
        var imageScale: Double?
        var isFromCapture: Bool?
    }

    private struct IndexEnvelope: Codable {
        var schemaVersion: Int
        var items: [ClipItem]
    }

    enum StoreError: Error {
        case keyUnavailable
    }

    /// 存储预算被收藏占满时通知 UI；由控制器切回主线程展示。
    var onStorageFull: (() -> Void)?
    /// 写回系统剪贴板后通知外部抑制下一次变化。
    var onSelfWrite: (() -> Void)?

    private let supportDir: URL
    private let cacheDir: URL
    private let pasteboard: NSPasteboard
    private let key: SymmetricKey
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.icut.app.clipboard.store")

    private var items: [ClipItem] = []
    private var saveWorkItem: DispatchWorkItem?
    private var storageFull = false
    /// 索引与备份都无法解密/解码时置位，供上层提示“历史损坏”
    private(set) var indexCorrupted = false
    private var retention: TimeInterval?
    private var maxEntries = ClipboardSettings.default.maxEntries
    private var imageBudgetBytes = ClipboardSettings.default.imageBudgetBytes
    /// 极小图片不会撑满容量，但会把索引条数撑爆；这是不暴露给用户的保护阀。
    private let maxImageEntries = 500

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        supportDir: URL? = nil,
        cacheDir: URL? = nil,
        pasteboard: NSPasteboard = .general,
        key: SymmetricKey? = nil
    ) throws {
        let supportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.supportDir = supportDir ?? supportBase.appendingPathComponent("iCut/Clipboard", isDirectory: true)
        self.cacheDir = cacheDir ?? cacheBase.appendingPathComponent("iCut/Clipboard", isDirectory: true)
        self.pasteboard = pasteboard

        guard let resolvedKey = key ?? ClipboardCrypto.masterKey else {
            throw StoreError.keyUnavailable
        }
        self.key = resolvedKey

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try prepareDirectories()
        items = loadItems()
    }

    // MARK: - 路径

    private var indexURL: URL { supportDir.appendingPathComponent("index.enc") }
    private var backupURL: URL { supportDir.appendingPathComponent("index.enc.bak") }
    private var imagesDir: URL { cacheDir.appendingPathComponent("images", isDirectory: true) }

    private func prepareDirectories() throws {
        for dir in [supportDir, imagesDir] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    // MARK: - 生命周期

    func configure(retention: TimeInterval?, maxEntries: Int, imageBudgetBytes: Int, now: Date = Date()) {
        queue.sync {
            self.retention = retention
            self.maxEntries = maxEntries
            self.imageBudgetBytes = imageBudgetBytes
            pruneLocked(now: now)
            scheduleSaveLocked()
        }
    }

    /// 打开面板前调用：过期条目在展示前清掉，列表里不会出现「已过期」。
    func pruneNow(now: Date = Date()) {
        queue.sync {
            pruneLocked(now: now)
            scheduleSaveLocked()
        }
    }

    /// 退出前强制落盘：防抖窗口里的最后一次变更不能丢。
    func saveNow() {
        queue.sync {
            saveWorkItem?.cancel()
            saveWorkItem = nil
            persistLocked()
        }
    }

    /// 测试用：等待排队中的工作完成，不触发落盘。
    func flush() {
        queue.sync {}
    }

    var count: Int { queue.sync { items.count } }

    var isStorageFull: Bool { queue.sync { storageFull } }

    // MARK: - 查询与写入

    func allItems() -> [ClipItem] {
        queue.sync { items }
    }

    func append(_ snapshot: PasteboardSnapshot, now: Date = Date(), isFromCapture: Bool = false) {
        queue.sync {
            // 同内容 5 分钟内重复：只提前到顶部并刷新时间，不新增
            if let index = items.firstIndex(where: { $0.hash == snapshot.hash }),
               now.timeIntervalSince(items[index].createdAt) < 300 {
                items[index].createdAt = now
                if isFromCapture { items[index].isFromCapture = true }
                let updated = items.remove(at: index)
                items.insert(updated, at: 0)
                scheduleSaveLocked()
                return
            }

            // 图片放不下时先淘汰最旧未收藏；收藏占满预算或单张超预算才跳过
            if snapshot.kind == .image {
                guard makeRoomForImageLocked(byteCount: snapshot.byteCount) else {
                    storageFull = true
                    DispatchQueue.main.async { [weak self] in self?.onStorageFull?() }
                    return
                }
            }

            let item = makeItemLocked(from: snapshot, now: now, isFromCapture: isFromCapture)
            items.insert(item, at: 0)
            pruneLocked(now: now)
            scheduleSaveLocked()
        }
    }

    func delete(id: UUID) {
        queue.sync {
            removeItemsLocked(ids: [id])
            storageFull = totalImageBytesLocked() > imageBudgetBytes
            scheduleSaveLocked()
        }
    }

    func setPinned(id: UUID, pinned: Bool) {
        queue.sync {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].isPinned = pinned
            storageFull = totalImageBytesLocked() > imageBudgetBytes
            scheduleSaveLocked()
        }
    }

    func clearAll() {
        queue.sync {
            removeItemsLocked(ids: Set(items.map(\.id)))
            items.removeAll()
            storageFull = false
            saveWorkItem?.cancel()
            saveWorkItem = nil
            persistLocked()
        }
    }

    /// 只清未永久保留的记录；收藏条目原样保留，图片密文同步删除。
    @discardableResult
    func clearUnpinned() -> Int {
        queue.sync {
            let ids = Set(items.filter { !$0.isPinned }.map(\.id))
            guard !ids.isEmpty else { return 0 }
            removeItemsLocked(ids: ids)
            storageFull = totalImageBytesLocked() > imageBudgetBytes
            saveWorkItem?.cancel()
            saveWorkItem = nil
            persistLocked()
            return ids.count
        }
    }

    /// 重建密钥/历史损坏时清空索引与图片密文，不做部分保留
    func resetAllData() {
        queue.sync {
            removeItemsLocked(ids: Set(items.map(\.id)))
            items.removeAll()
            storageFull = false
            indexCorrupted = false
            saveWorkItem?.cancel()
            saveWorkItem = nil
            try? fileManager.removeItem(at: indexURL)
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.removeItem(at: imagesDir)
            try? fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imagesDir.path)
        }
    }

    /// 回填剪贴板；失败时保持历史不变，由面板提示。
    @discardableResult
    func writeBack(_ item: ClipItem) -> Bool {
        queue.sync {
            let ok: Bool
            switch item.kind {
            case .text:
                guard let text = item.text else { return false }
                pasteboard.clearContents()
                if let rtf = item.rtfData {
                    pasteboard.setData(rtf, forType: .rtf)
                }
                ok = pasteboard.setString(text, forType: .string)

            case .image:
                guard let data = imageDataLocked(item),
                      let image = sizedImage(data: data, scale: item.imageScale) else {
                    return false
                }
                pasteboard.clearContents()
                ok = pasteboard.writeObjects([image])

            case .fileURLs:
                let paths = item.filePaths ?? []
                guard !paths.isEmpty else { return false }
                // 路径只记引用：回填前复核一次，原文件失效时拒绝写入，避免粘贴后才报错
                guard paths.allSatisfy({ fileManager.fileExists(atPath: $0) }) else {
                    NSLog("iCut: 剪贴板回填失败 — 文件已不存在")
                    return false
                }
                let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
                pasteboard.clearContents()
                ok = pasteboard.writeObjects(urls)
            }
            if ok { onSelfWrite?() }
            return ok
        }
    }

    func imageData(for item: ClipItem) -> Data? {
        queue.sync { imageDataLocked(item) }
    }

    // MARK: - 加密落盘

    private func makeItemLocked(from snapshot: PasteboardSnapshot, now: Date, isFromCapture: Bool) -> ClipItem {
        var imageFile: String?
        if let png = snapshot.imagePNG, let sealed = ClipboardCrypto.seal(png, using: key) {
            let name = "\(UUID().uuidString).png.enc"
            let url = imagesDir.appendingPathComponent(name)
            do {
                try sealed.write(to: url, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                imageFile = name
            } catch {
                NSLog("iCut: 剪贴板图片写入失败 — \(error)")
            }
        }

        return ClipItem(
            id: UUID(),
            kind: ClipItem.Kind(rawValue: snapshot.kind.rawValue) ?? .text,
            createdAt: now,
            text: snapshot.text,
            rtfData: snapshot.rtfData,
            imageFile: imageFile,
            thumbnailPNG: snapshot.thumbnailPNG,
            filePaths: snapshot.filePaths.isEmpty ? nil : snapshot.filePaths,
            isPinned: false,
            hash: snapshot.hash,
            byteCount: snapshot.byteCount,
            isTruncated: snapshot.isTruncated,
            imageScale: snapshot.kind == .image ? Double(snapshot.imageScale) : nil,
            isFromCapture: isFromCapture ? true : nil
        )
    }

    private func loadItems() -> [ClipItem] {
        var sawIndexFile = false
        for url in [indexURL, backupURL] {
            if fileManager.fileExists(atPath: url.path) { sawIndexFile = true }
            guard let encrypted = try? Data(contentsOf: url),
                  let decrypted = ClipboardCrypto.open(encrypted, using: key),
                  let envelope = try? decoder.decode(IndexEnvelope.self, from: decrypted) else {
                continue
            }
            guard envelope.schemaVersion <= 1 else {
                NSLog("iCut: 剪贴板历史索引版本过新（\(envelope.schemaVersion)），跳过")
                continue
            }
            if url == backupURL {
                NSLog("iCut: 剪贴板历史索引损坏，已回退到备份")
            }
            return envelope.items.sorted { $0.createdAt > $1.createdAt }
        }
        indexCorrupted = sawIndexFile
        return []
    }

    private func scheduleSaveLocked() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistLocked()
        }
        saveWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func persistLocked() {
        let envelope = IndexEnvelope(schemaVersion: 1, items: items)
        guard let data = try? encoder.encode(envelope),
              let sealed = ClipboardCrypto.seal(data, using: key) else {
            NSLog("iCut: 剪贴板历史序列化或加密失败，保留旧索引")
            return
        }

        let tempURL = supportDir.appendingPathComponent("index.enc.tmp")
        do {
            try sealed.write(to: tempURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            // 显式刷盘：原子替换前把数据落稳定，掉电时少丢一次变更
            if let handle = try? FileHandle(forWritingTo: tempURL) {
                try? handle.synchronize()
                try? handle.close()
            }

            if fileManager.fileExists(atPath: indexURL.path) {
                try? fileManager.removeItem(at: backupURL)
                try fileManager.moveItem(at: indexURL, to: backupURL)
            }
            try fileManager.moveItem(at: tempURL, to: indexURL)
        } catch {
            NSLog("iCut: 剪贴板历史写入失败 — \(error)")
            try? fileManager.removeItem(at: tempURL)
        }
    }

    // MARK: - 淘汰

    private func pruneLocked(now: Date) {
        var doomed = Set<UUID>()

        if let retention {
            for item in items where !item.isPinned && now.timeIntervalSince(item.createdAt) > retention {
                doomed.insert(item.id)
            }
        }

        // 非图片条目受条数上限约束；图片只受容量预算约束
        let nonImages = items.filter { $0.kind != .image && !$0.isPinned }
        for item in nonImages.dropFirst(maxEntries) {
            doomed.insert(item.id)
        }

        let images = items.filter { $0.kind == .image }
        var imageBytes = images.reduce(0) { $0 + $1.byteCount }
        var imageCount = images.count
        if imageBytes > imageBudgetBytes || imageCount > maxImageEntries {
            let evictable = images.filter { !$0.isPinned }.sorted { $0.createdAt < $1.createdAt }
            for item in evictable {
                guard imageBytes > imageBudgetBytes || imageCount > maxImageEntries else { break }
                doomed.insert(item.id)
                imageBytes -= item.byteCount
                imageCount -= 1
            }
        }

        if !doomed.isEmpty {
            removeItemsLocked(ids: doomed)
        }
        storageFull = imageBytes > imageBudgetBytes
    }

    private func removeItemsLocked(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        for item in removed {
            if let name = item.imageFile {
                try? fileManager.removeItem(at: imagesDir.appendingPathComponent(name))
            }
        }
    }

    private func imageDataLocked(_ item: ClipItem) -> Data? {
        guard let name = item.imageFile else { return nil }
        let url = imagesDir.appendingPathComponent(name)
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        return ClipboardCrypto.open(sealed, using: key)
    }

    private func totalImageBytesLocked() -> Int {
        items.filter { $0.kind == .image }.reduce(0) { $0 + $1.byteCount }
    }

    /// 给新图片腾空间：按最旧未收藏淘汰，预算或条数仍不够时返回 false。
    /// 收藏不参与淘汰；收藏占满预算时由调用方提示，不静默删除收藏。
    private func makeRoomForImageLocked(byteCount: Int) -> Bool {
        guard byteCount <= imageBudgetBytes else { return false }

        let images = items.filter { $0.kind == .image }
        var imageBytes = images.reduce(0) { $0 + $1.byteCount }
        var imageCount = images.count
        guard imageBytes + byteCount > imageBudgetBytes || imageCount + 1 > maxImageEntries else {
            return true
        }

        // 每次淘汰最旧的一张未收藏图片，直到预算与条数都放得下
        let evictable = images.filter { !$0.isPinned }.sorted { $0.createdAt < $1.createdAt }
        var doomed = Set<UUID>()
        for item in evictable {
            guard imageBytes + byteCount > imageBudgetBytes || imageCount + 1 > maxImageEntries else { break }
            doomed.insert(item.id)
            imageBytes -= item.byteCount
            imageCount -= 1
        }
        if !doomed.isEmpty {
            removeItemsLocked(ids: doomed)
        }
        return imageBytes + byteCount <= imageBudgetBytes && imageCount + 1 <= maxImageEntries
    }

    /// PNG 只存像素；不还原点尺寸就会被当成 1x 图，粘贴到文档里尺寸翻倍。
    private func sizedImage(data: Data, scale: Double?) -> NSImage? {
        guard let rep = NSBitmapImageRep(data: data) else {
            return NSImage(data: data)
        }
        let factor = max(CGFloat(scale ?? 1), 0.1)
        rep.size = NSSize(
            width: CGFloat(rep.pixelsWide) / factor,
            height: CGFloat(rep.pixelsHigh) / factor
        )
        let image = NSImage()
        image.addRepresentation(rep)
        return image
    }
}
