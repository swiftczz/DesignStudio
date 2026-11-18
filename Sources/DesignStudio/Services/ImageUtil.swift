import AppKit
import UniformTypeIdentifiers

enum ImageUtil {
    /// 读取图片并压缩到合适的尺寸（长边 ≤ 1568px，JPEG）
    static func attachment(from url: URL) -> ChatAttachment? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return attachment(from: image, name: url.lastPathComponent)
    }

    static func attachment(from image: NSImage, name: String) -> ChatAttachment? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxSide: CGFloat = 1568
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return ChatAttachment(filename: name, mimeType: "image/jpeg", data: data)
    }

    static func pngData(_ image: NSImage, maxWidth: CGFloat? = nil) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var source = cg
        if let maxWidth, CGFloat(cg.width) > maxWidth {
            let scale = maxWidth / CGFloat(cg.width)
            let tw = Int(maxWidth), th = max(1, Int(CGFloat(cg.height) * scale))
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
                if let scaled = ctx.makeImage() { source = scaled }
            }
        }
        return NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])
    }

    @MainActor
    static func pickImages() -> [ChatAttachment] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(attachment(from:))
    }
}
