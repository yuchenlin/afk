import AppKit
import CoreGraphics

/// The AFK mark (design/logo/afk-logo-*.svg): two eyes above a sound-wave smile.
/// Geometry is in the SVG's 1024×1024 canvas (y down) and shared by the app icon export
/// (scripts/make-icons.swift) and the menu bar icon, so they always match.
public enum LogoMark {
    public static let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    /// Tight bounds of the eyes and bars within the canvas.
    public static let markBounds = CGRect(x: 305, y: 332, width: 414, height: 403)

    static let eyes: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [(402, 380, 48), (622, 380, 48)]
    static let bars: [CGRect] = [
        CGRect(x: 305, y: 578.3, width: 54, height: 70),
        CGRect(x: 395, y: 600.8, width: 54, height: 110),
        CGRect(x: 485, y: 605.0, width: 54, height: 130),
        CGRect(x: 575, y: 600.8, width: 54, height: 110),
        CGRect(x: 665, y: 578.3, width: 54, height: 70),
    ]

    /// The mark's shapes, mapping `source` (SVG coordinates) into `rect` (Core Graphics
    /// coordinates, y up), scaled to fit and centered.
    public static func path(fitting rect: CGRect, source: CGRect = canvas) -> CGPath {
        let scale = min(rect.width / source.width, rect.height / source.height)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - source.midX) * scale, y: rect.midY - (y - source.midY) * scale)
        }
        let path = CGMutablePath()
        for eye in eyes {
            let c = map(eye.x, eye.y)
            let r = eye.r * scale
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        for bar in bars {
            let origin = map(bar.minX, bar.maxY)
            let frame = CGRect(x: origin.x, y: origin.y, width: bar.width * scale, height: bar.height * scale)
            let corner = min(frame.width, frame.height) / 2 - 0.0001
            path.addRoundedRect(in: frame, cornerWidth: corner, cornerHeight: corner)
        }
        return path
    }

    /// 18 pt template image for the menu bar. `active` inverts it (a filled rounded square
    /// with the face cut out) to show that AFK is recording.
    public static func menuBarImage(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            if active {
                let box = rect.insetBy(dx: 0.5, dy: 0.5)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
                ctx.addPath(path(fitting: box.insetBy(dx: 3.5, dy: 3.5), source: markBounds))
                ctx.fillPath(using: .evenOdd)
            } else {
                ctx.addPath(path(fitting: rect.insetBy(dx: 1.5, dy: 1.5), source: markBounds))
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "AFK recording" : "AFK"
        return image
    }
}
