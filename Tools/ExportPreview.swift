import AppKit
import SwiftUI

@main
struct ExportPreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        let state = ProcessInfo.processInfo.environment["AWAKE_PREVIEW_STATE"] ?? "active"
        let host = NSHostingView(
            rootView: MenuPanel(model: .preview(state))
                .environment(\.controlActiveState, .key)
                .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = app.appearance
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.setContentSize(host.fittingSize)
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: output, options: .atomic)
        print("Preview: \(bitmap.pixelsWide) × \(bitmap.pixelsHigh) PNG")
    }
}
