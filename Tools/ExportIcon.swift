import AppKit
import Foundation

@main
struct ExportIcon {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                guard
                    let bitmap = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                        samplesPerPixel: 4,
                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: bitmap)
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                BrandArt.appIcon(size: CGFloat(pixels)).draw(
                    in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        }
    }
}
