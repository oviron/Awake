import AppKit

@MainActor enum BrandArt {
    private static func loop(in rect: NSRect) -> NSBezierPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let path = NSBezierPath()
        path.move(to: point(0.48, 0.50))
        path.curve(
            to: point(0.08, 0.50), controlPoint1: point(0.22, 0.95),
            controlPoint2: point(0.02, 0.85))
        path.curve(
            to: point(0.53, 0.51), controlPoint1: point(0.15, 0.05),
            controlPoint2: point(0.35, 0.18))
        path.curve(
            to: point(0.93, 0.55), controlPoint1: point(0.79, 0.89),
            controlPoint2: point(0.96, 0.84))
        path.curve(
            to: point(0.62, 0.37), controlPoint1: point(0.90, 0.23),
            controlPoint2: point(0.78, 0.19))
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    static let menuIdle = menuImage()

    static let github: NSImage = {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M6.766 11.328c-2.063-.25-3.516-1.734-3.516-3.656 0-.781.281-1.625.75-2.188-.203-.515-.172-1.609.063-2.062.625-.078 1.468.25 1.968.703.594-.187 1.219-.281 1.985-.281.765 0 1.39.094 1.953.265.484-.437 1.344-.765 1.969-.687.218.422.25 1.515.046 2.047.5.593.766 1.39.766 2.203 0 1.922-1.453 3.375-3.547 3.64.531.344.89 1.094.89 1.954v1.625c0 .468.391.734.86.547C13.781 14.359 16 11.53 16 8.03 16 3.61 12.406 0 7.984 0 3.563 0 0 3.61 0 8.031a7.88 7.88 0 0 0 5.172 7.422c.422.156.828-.125.828-.547v-1.25c-.219.094-.5.156-.75.156-1.031 0-1.64-.562-2.078-1.609-.172-.422-.36-.672-.719-.719-.187-.015-.25-.093-.25-.187 0-.188.313-.328.625-.328.453 0 .844.281 1.25.86.313.452.64.655 1.031.655s.641-.14 1-.5c.266-.265.47-.5.657-.656"/></svg>
            """
        let image = NSImage(data: Data(svg.utf8))!
        image.isTemplate = true
        return image
    }()

    private static func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 23, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let path = loop(in: NSRect(x: 1, y: 1, width: 21, height: 16))
            path.lineWidth = 1.8
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Awake"
        return image
    }

    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            let frame = bounds.insetBy(dx: size * 0.08, dy: size * 0.08)
            let tile = NSBezierPath(roundedRect: frame, xRadius: size * 0.19, yRadius: size * 0.19)
            NSGradient(
                starting: NSColor(srgbRed: 0.24, green: 0.35, blue: 0.73, alpha: 1),
                ending: NSColor(srgbRed: 0.09, green: 0.13, blue: 0.40, alpha: 1))?
                .draw(in: tile, angle: -90)
            NSColor.white.withAlphaComponent(0.30).setStroke()
            tile.lineWidth = max(1, size * 0.003)
            tile.stroke()
            let mark = loop(in: frame.insetBy(dx: size * 0.13, dy: size * 0.18))
            mark.lineWidth = size * 0.055
            NSColor(srgbRed: 0.92, green: 0.96, blue: 1, alpha: 1).setStroke()
            mark.stroke()
            return true
        }
    }
}
