// Renders the AFK icons from LogoMark (the same geometry as design/logo/afk-logo-*.svg).
// Built and run by `make icons`:
//   <out>/AppIcon.iconset/…      macOS sizes 16–1024 (rounded square, standard margin and shadow)
//   <out>/ios-AppIcon-1024.png   iOS App Store icon: full-bleed square, opaque (iOS rounds it)
//   <out>/menubar-18@2x.png      menu bar template icons, for reference
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
enum MakeIcons {
    static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "design/icons")
        let iconset = out.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        let macSizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in macSizes {
            try write(macIcon(px), to: iconset.appendingPathComponent("\(name).png"))
        }
        try write(iosIcon(1024), to: out.appendingPathComponent("ios-AppIcon-1024.png"))
        try write(menuBar(active: false), to: out.appendingPathComponent("menubar-18@2x.png"))
        try write(menuBar(active: true), to: out.appendingPathComponent("menubar-18-active@2x.png"))
        print("wrote icons to \(out.path)")
    }

    /// macOS icon grid: 824/1024 rounded square with a 100 px margin and a soft shadow.
    static func macIcon(_ px: Int) -> CGImage {
        let s = CGFloat(px) / 1024
        return render(px, px, opaque: false) { ctx in
            let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            let shape = CGPath(roundedRect: body, cornerWidth: 185.4 * s, cornerHeight: 185.4 * s, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s,
                          color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(shape)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(LogoMark.path(fitting: body))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
        }
    }

    /// App Store requires a square, opaque 1024 px image; the system applies the corner mask.
    static func iosIcon(_ px: Int) -> CGImage {
        render(px, px, opaque: true) { ctx in
            let full = CGRect(x: 0, y: 0, width: px, height: px)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(full)
            ctx.addPath(LogoMark.path(fitting: full))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
        }
    }

    static func menuBar(active: Bool) -> CGImage {
        let image = LogoMark.menuBarImage(active: active)
        return render(36, 36, opaque: false) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func render(_ w: Int, _ h: Int, opaque: Bool, draw: (CGContext) -> Void) -> CGImage {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        ctx.setShouldAntialias(true)
        draw(ctx)
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
