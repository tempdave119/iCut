import AppKit

enum ClipboardService {
    /// 把像素图写入系统剪贴板。带上 scale 换算后的点尺寸，粘贴到文档类应用才不会当成超大图。
    @discardableResult
    static func copy(image: CGImage, scale: CGFloat) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let nsImage = NSImage()
        nsImage.addRepresentation(rep)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([nsImage])
    }
}
