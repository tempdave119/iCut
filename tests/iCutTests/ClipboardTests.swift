import AppKit
import CryptoKit

/// 剪贴板历史的纯逻辑与存储测试：不依赖真实钥匙串与真实系统剪贴板。
func runClipboardCryptoTests() {
    let key = ClipboardCrypto.randomKey()
    let plain = Data("iCut 剪贴板历史".utf8)

    guard let sealed = ClipboardCrypto.seal(plain, using: key) else {
        expect(false, "AES-GCM 加密应成功")
        return
    }
    expectEqual(ClipboardCrypto.open(sealed, using: key), plain, "解密应还原原文")
    expect(sealed != plain, "密文不应与明文相同")
    expect(
        ClipboardCrypto.open(sealed, using: ClipboardCrypto.randomKey()) == nil,
        "错误密钥不能解出内容"
    )
    expect(ClipboardCrypto.open(Data("not-sealed".utf8), using: key) == nil, "损坏密文应解密失败")
}

func runCaptureMarkTests() {
    var mark = CaptureMark()
    mark.note(changeCount: 5)
    expectEqual(mark.consume(changeCount: 5), true, "匹配 changeCount 应标记为截图")
    expectEqual(mark.consume(changeCount: 5), false, "标记只能消费一次")
    mark.note(changeCount: 8)
    expectEqual(mark.consume(changeCount: 9), false, "不同 changeCount 不应命中")
    mark.reset()
    expectEqual(mark.consume(changeCount: 8), false, "reset 后不应命中")
}

func runPasteboardWatcherTests() {
    let watcher = PasteboardWatcher(
        pasteboard: NSPasteboard(name: NSPasteboard.Name("iCutWatcher.\(UUID().uuidString)"))
    )
    watcher.noteSelfWrite(changeCount: 5)
    expectEqual(watcher.shouldSuppress(changeCount: 5), true, "自写计数命中应抑制")
    expectEqual(watcher.shouldSuppress(changeCount: 5), false, "抑制只能消费一次")
    watcher.noteSelfWrite(changeCount: 8)
    expectEqual(watcher.shouldSuppress(changeCount: 9), false, "不同计数不应抑制")
}

func runClipboardSettingsTests() {
    let fallback = ClipboardSettings.default
    expectEqual(fallback.enabled, false, "剪贴板历史默认关闭")
    expectEqual(fallback.recordImages, true, "默认记录图片")
    expectEqual(fallback.maxEntries, 200, "默认条数 200")
    expectEqual(fallback.imageBudgetMB, 200, "默认图片预算 200MB")
    expectEqual(fallback.retentionDays, 7, "默认保留 7 天")
    expectEqual(fallback.keepPanelOpen, false, "默认复制后不保持面板打开")
    expectEqual(fallback.imageBudgetBytes, 200 * 1024 * 1024, "预算换算为字节")
    expectEqual(fallback.retentionInterval, 7 * 86_400, "保留期换算为秒")

    var permanent = fallback
    permanent.retentionDays = 0
    expect(permanent.retentionInterval == nil, "0 天表示永久保留")

    expectEqual(HotKeyConfig.clipboardDefault.displayText, "⌃⌥V", "剪贴板默认热键")
    expectEqual(HotKeySlot.clipboard.keyPrefix, "hotkey.clipboard", "剪贴板热键键名前缀")
    expectEqual(HotKeySlot.capture.keyPrefix, "hotkey", "截图热键沿用旧键名")
}

func runPasteboardSnapshotTests() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("iCutTest.\(UUID().uuidString)"))

    pasteboard.clearContents()
    _ = pasteboard.setString("hello icut", forType: .string)
    let textSnapshot = PasteboardSnapshot.parse(pasteboard, recordImages: true)
    expectEqual(textSnapshot?.kind, PasteboardSnapshot.Kind.text, "识别文本")
    expectEqual(textSnapshot?.text, "hello icut", "保留原文")
    expect(textSnapshot?.hash.isEmpty == false, "生成内容哈希")

    // 敏感标记：只要出现就整条丢弃
    pasteboard.clearContents()
    _ = pasteboard.setString("password", forType: .string)
    _ = pasteboard.setData(
        Data([1]),
        forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    )
    expect(
        PasteboardSnapshot.parse(pasteboard, recordImages: true) == nil,
        "concealed 标记的内容不应进入历史"
    )

    let longText = String(repeating: "a", count: PasteboardSnapshot.maxTextBytes + 10)
    pasteboard.clearContents()
    _ = pasteboard.setString(longText, forType: .string)
    let truncated = PasteboardSnapshot.parse(pasteboard, recordImages: true)
    expectEqual(truncated?.text?.count, PasteboardSnapshot.maxTextBytes, "超长文本按字节截断")
    expectEqual(truncated?.isTruncated, true, "截断应被标记")

    guard let png = makeTestPNG() else {
        expect(false, "测试图片生成失败")
        return
    }
    pasteboard.clearContents()
    _ = pasteboard.setData(png, forType: .png)
    let imageSnapshot = PasteboardSnapshot.parse(pasteboard, recordImages: true)
    expectEqual(imageSnapshot?.kind, PasteboardSnapshot.Kind.image, "识别图片")
    expect(imageSnapshot?.thumbnailPNG != nil, "图片应生成缩略图")
    expectEqual(imageSnapshot?.imageScale, CGFloat(1), "无点尺寸信息时按 1x 处理")
    expect(
        PasteboardSnapshot.parse(pasteboard, recordImages: false) == nil,
        "关闭图片记录时不解析图片"
    )

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iCutSnapshotTest-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let fileURL = tempDir.appendingPathComponent("note.txt")
    try? "x".write(to: fileURL, atomically: true, encoding: .utf8)

    pasteboard.clearContents()
    _ = pasteboard.writeObjects([fileURL as NSURL])
    let fileSnapshot = PasteboardSnapshot.parse(pasteboard, recordImages: true)
    expectEqual(fileSnapshot?.kind, PasteboardSnapshot.Kind.fileURLs, "识别文件路径")
    expectEqual(fileSnapshot?.filePaths, [fileURL.path], "只记录路径引用")
    try? FileManager.default.removeItem(at: tempDir)
}

func runClipboardExpiryTests() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let created = now.addingTimeInterval(-86_400)

    expectEqual(
        ClipboardExpiry.text(createdAt: created, isPinned: false, retention: 7 * 86_400, now: now),
        "6 天后过期",
        "7 天保留期应剩 6 天"
    )
    expectEqual(
        ClipboardExpiry.text(createdAt: created, isPinned: true, retention: 7 * 86_400, now: now),
        "永久保留",
        "收藏条目不显示过期"
    )
    expectEqual(
        ClipboardExpiry.text(createdAt: created, isPinned: false, retention: nil, now: now),
        "不过期",
        "永久保留期应显示不过期"
    )
    expectEqual(
        ClipboardExpiry.text(
            createdAt: now.addingTimeInterval(-10 * 86_400),
            isPinned: false,
            retention: 86_400,
            now: now
        ),
        "已过期",
        "超期应显示已过期"
    )
    expectEqual(
        ClipboardExpiry.text(
            createdAt: now.addingTimeInterval(-10 * 60),
            isPinned: false,
            retention: 86_400,
            now: now
        ),
        "23 小时后过期",
        "不足一天按小时显示"
    )
}

func runClipboardStoreTests() {
    let key = ClipboardCrypto.randomKey()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("iCutClipboardTest-\(UUID().uuidString)", isDirectory: true)
    let supportDir = root.appendingPathComponent("support", isDirectory: true)
    let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func makeStore(pasteboard: NSPasteboard? = nil) -> ClipboardStore? {
        try? ClipboardStore(
            supportDir: supportDir,
            cacheDir: cacheDir,
            pasteboard: pasteboard ?? NSPasteboard(name: NSPasteboard.Name("iCutStore.\(UUID().uuidString)")),
            key: key
        )
    }

    guard let textA = makeTextSnapshot("alpha"),
          let textB = makeTextSnapshot("beta"),
          let textC = makeTextSnapshot("gamma"),
          let store = makeStore() else {
        expect(false, "测试仓库或快照初始化失败")
        return
    }

    let now = Date()

    // 追加与去重
    store.append(textA, now: now.addingTimeInterval(-900))
    store.append(textB, now: now.addingTimeInterval(-600))
    expectEqual(store.count, 2, "两条不同文本都应记录")
    store.append(textA, now: now.addingTimeInterval(-700))
    expectEqual(store.count, 2, "5 分钟内重复内容不新增")

    // 条数淘汰
    store.configure(retention: nil, maxEntries: 2, imageBudgetBytes: 200 * 1024 * 1024)
    store.append(textC, now: now.addingTimeInterval(-300))
    expectEqual(store.count, 2, "超过条数上限应淘汰最旧")
    expectEqual(store.allItems().first?.text, "gamma", "最新内容排在最前")

    // 收藏跳过条数淘汰
    guard let pinned = store.allItems().first else {
        expect(false, "应有可收藏条目")
        return
    }
    store.setPinned(id: pinned.id, pinned: true)
    store.append(makeTextSnapshot("delta")!, now: now.addingTimeInterval(-120))
    expectEqual(store.count, 3, "收藏条目不占淘汰名额")
    expect(
        store.allItems().contains { $0.id == pinned.id },
        "永久保留条目不应被条数淘汰"
    )

    // 保留期淘汰：先写入旧条目，再按当前时间清理
    store.append(makeTextSnapshot("expired")!, now: now.addingTimeInterval(-10 * 86_400))
    store.configure(retention: 7 * 86_400, maxEntries: 200, imageBudgetBytes: 200 * 1024 * 1024)
    let hasExpired = store.allItems().contains { $0.text == "expired" }
    expectEqual(hasExpired, false, "超出保留期的条目应被清理")
    store.saveNow()

    // 加密落盘：索引中不能出现明文
    guard let writer = makeStore() else {
        expect(false, "落盘测试仓库初始化失败")
        return
    }
    writer.clearAll()
    writer.append(makeTextSnapshot("secret-needle")!, now: now)
    writer.saveNow()

    let indexURL = supportDir.appendingPathComponent("index.enc")
    let raw = (try? Data(contentsOf: indexURL)) ?? Data()
    expect(!raw.isEmpty, "索引文件应已落盘")
    expect(raw.range(of: Data("secret-needle".utf8)) == nil, "索引文件中不应出现明文")

    // 损坏回退：写坏 index.enc 后应从 .bak 恢复
    writer.append(makeTextSnapshot("second-save")!, now: now)
    writer.saveNow()
    try? Data("broken".utf8).write(to: indexURL)
    if let recovered = makeStore() {
        expect(recovered.count > 0, "索引损坏时应回退到备份")
    } else {
        expect(false, "回退测试的仓库初始化失败")
    }

    // 回填：写入指定剪贴板
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("iCutStoreTest.\(UUID().uuidString)"))
    if let store = makeStore(pasteboard: pasteboard) {
        store.append(makeTextSnapshot("paste-me")!, now: Date())
        if let item = store.allItems().first {
            expectEqual(store.writeBack(item), true, "文本回填应成功")
            expectEqual(pasteboard.string(forType: .string), "paste-me", "剪贴板应拿到原文")
        } else {
            expect(false, "回填测试缺少条目")
        }
    }

    // 截图来源标记
    if let store = makeStore() {
        store.clearAll()
        store.append(makeTextSnapshot("capture-mark")!, now: Date(), isFromCapture: true)
        expectEqual(store.allItems().first?.isFromCapture, true, "截图来源应被标记")
    }

    // 打开面板前的即时清理：过期条目不应出现在列表里
    if let store = makeStore() {
        store.clearAll()
        store.configure(retention: 7 * 86_400, maxEntries: 200, imageBudgetBytes: 200 * 1024 * 1024)
        store.append(makeTextSnapshot("stale")!, now: Date().addingTimeInterval(-10 * 86_400))
        store.pruneNow()
        expectEqual(store.count, 0, "pruneNow 应清掉过期条目")
    }

    // 只清未收藏：收藏保留
    if let store = makeStore() {
        store.clearAll()
        store.append(makeTextSnapshot("keep")!, now: Date())
        store.append(makeTextSnapshot("remove")!, now: Date())
        if let keep = store.allItems().first(where: { $0.text == "keep" }) {
            store.setPinned(id: keep.id, pinned: true)
        }
        let removed = store.clearUnpinned()
        expectEqual(removed, 1, "只应清除未收藏的 1 条")
        expectEqual(store.count, 1, "收藏记录应保留")
        expectEqual(store.allItems().first?.text, "keep", "保留的是收藏条目")
    }

    // 图片预算：收藏占满时新图片跳过，收藏本身保留
    if let store = makeStore() {
        store.clearAll()
        guard let red = makeImageSnapshot(color: .systemRed) else {
            expect(false, "图片快照构造失败")
            return
        }
        store.append(red, now: Date())
        expectEqual(store.count, 1, "图片应被记录")
        if let item = store.allItems().first {
            store.setPinned(id: item.id, pinned: true)
        }
        store.configure(retention: nil, maxEntries: 200, imageBudgetBytes: 1)
        expectEqual(store.isStorageFull, true, "收藏占满预算应标记")
        expectEqual(store.count, 1, "收藏图片不应被淘汰")

        if let blue = makeImageSnapshot(color: .systemBlue) {
            store.append(blue, now: Date())
            expectEqual(store.count, 1, "预算已满时新图片应跳过")
        }
    }

    // 图片预算：未收藏时淘汰最旧图片，让新图进来（D1）
    if let store = makeStore() {
        store.clearAll()
        guard let red = makeImageSnapshot(color: .systemRed),
              let blue = makeImageSnapshot(color: .systemBlue) else {
            expect(false, "图片淘汰测试快照构造失败")
            return
        }
        store.configure(retention: nil, maxEntries: 200, imageBudgetBytes: 200 * 1024 * 1024)
        store.append(red, now: Date().addingTimeInterval(-60))
        store.configure(retention: nil, maxEntries: 200, imageBudgetBytes: red.byteCount + 1)
        store.append(blue, now: Date())
        expectEqual(store.count, 1, "预算不足时应淘汰最旧未收藏图片")
        expectEqual(store.allItems().first?.hash, blue.hash, "应保留刚复制的新图片")
    }

    // 文件回填：原文件已删除时应拒绝
    if let store = makeStore() {
        store.clearAll()
        let fileURL = root.appendingPathComponent("gone-\(UUID().uuidString).txt")
        try? "x".write(to: fileURL, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("iCutStoreFile.\(UUID().uuidString)"))
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([fileURL as NSURL])
        if let snapshot = PasteboardSnapshot.parse(pasteboard, recordImages: true) {
            store.append(snapshot)
            try? FileManager.default.removeItem(at: fileURL)
            if let item = store.allItems().first {
                expectEqual(store.writeBack(item), false, "文件已不存在时不应回填")
            } else {
                expect(false, "文件回填测试缺少条目")
            }
        } else {
            expect(false, "文件回填测试快照解析失败")
        }
    }

    // 重建密钥/历史损坏时的清空
    if let store = makeStore() {
        store.append(makeTextSnapshot("reset-me")!, now: Date())
        store.saveNow()
        store.resetAllData()
        expectEqual(store.count, 0, "resetAllData 应清空条目")
        let indexURL = supportDir.appendingPathComponent("index.enc")
        expectEqual(FileManager.default.fileExists(atPath: indexURL.path), false, "resetAllData 应删除索引")
    }
}

// MARK: - 测试辅助

private func makeTestPNG(color: NSColor = .systemRed) -> Data? {
    let width = 4
    let height = 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else { return nil }
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

private func makeTextSnapshot(_ text: String) -> PasteboardSnapshot? {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("iCutSnapshot.\(UUID().uuidString)"))
    pasteboard.clearContents()
    _ = pasteboard.setString(text, forType: .string)
    return PasteboardSnapshot.parse(pasteboard, recordImages: true)
}

private func makeImageSnapshot(color: NSColor = .systemRed) -> PasteboardSnapshot? {
    guard let png = makeTestPNG(color: color) else { return nil }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("iCutSnapshot.\(UUID().uuidString)"))
    pasteboard.clearContents()
    _ = pasteboard.setData(png, forType: .png)
    return PasteboardSnapshot.parse(pasteboard, recordImages: true)
}
