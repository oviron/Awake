import AppKit
import AwakeSystem
import Carbon
import Darwin
import Observation
import SwiftUI

@main
enum AwakeApp {
    @MainActor static func main() {
        guard geteuid() != 0 else { exit(1) }
        if CommandLine.arguments.dropFirst().first == "--finish-update" {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 3, let parent = Int32(args[2]) else { exit(64) }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                do {
                    let installed = try await GitHubUpdate.finish(
                        app: URL(fileURLWithPath: args[1]), parentPID: parent)
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    do {
                        _ = try await NSWorkspace.shared.openApplication(
                            at: installed.app, configuration: configuration)
                    } catch {
                        _ = try FileManager.default.replaceItemAt(
                            installed.app, withItemAt: installed.backup,
                            options: .usingNewMetadataOnly)
                        throw error
                    }
                    try? FileManager.default.removeItem(at: installed.backup)
                    try? FileManager.default.removeItem(at: installed.staging)
                    exit(0)
                } catch {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    let recoveryApp =
                        (try? await GitHubUpdate.currentInstalledApplication(
                            identity: SignedIdentity(
                                expectedIdentifier: AwakeIdentity.application)))
                        ?? Bundle.main.bundleURL
                    _ = try? await NSWorkspace.shared.openApplication(
                        at: recoveryApp, configuration: configuration)
                    let alert = NSAlert()
                    alert.messageText = "Update incomplete"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    app.activate()
                    alert.runModal()
                    exit(1)
                }
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--prepare-uninstall") {
            let options = Array(CommandLine.arguments.dropFirst())
            guard
                options == ["--prepare-uninstall"]
                    || options == ["--prepare-uninstall", "--erase-preferences"]
            else {
                FileHandle.standardError.write(
                    Data("Usage: AwakeApp --prepare-uninstall [--erase-preferences]\n".utf8))
                exit(64)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSMenuItemValidation {
    let model: AppModel
    private var previewWindow: NSWindow?
    private var terminating = false
    private var statusItem: NSStatusItem?
    private var lastPresentation: PowerPresentation?
    private let activeDot = StatusDot()
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var removalWindow: NSWindow?

    override init() {
        #if DEBUG
            let arguments = CommandLine.arguments
            let preview =
                arguments.firstIndex(of: "--preview").flatMap {
                    $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
                } ?? Bundle.main.object(forInfoDictionaryKey: "AwakePreviewState") as? String
            if let preview {
                model = AppModel.preview(preview)
            } else {
                model = AppModel()
            }
        #else
            model = AppModel()
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = BrandArt.appIcon(size: 256)
        if !CommandLine.arguments.contains("--prepare-uninstall") { installStatusItem() }
        Task {
            await model.prepareForLaunch()
            if CommandLine.arguments.contains("--prepare-uninstall") {
                let success = await model.removeIntegration()
                let output = (model.message ?? "Removal was not confirmed.") + "\n"
                (success ? FileHandle.standardOutput : FileHandle.standardError).write(
                    Data(output.utf8))
                exit(success ? 0 : 1)
            }
            await model.restoreUpdateHelperIfNeeded()
            model.beginMonitoring()
        }
        #if DEBUG
            if model.isPreview {
                if CommandLine.arguments.contains("--light") {
                    NSApp.appearance = NSAppearance(
                        named: CommandLine.arguments.contains("--contrast")
                            ? .accessibilityHighContrastAqua : .aqua)
                }
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 360, height: 620),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Awake — Read-only preview"
                window.contentView = NSHostingView(rootView: MenuPanel(model: model))
                window.center()
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
                NSApp.activate()
                previewWindow = window
            }
        #endif
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = AwakeIdentity.application
        statusItem = item
        item.button?.image = BrandArt.menuIdle
        item.button?.setAccessibilityLabel("Awake: Setup required")
        item.button?.target = self
        item.button?.action = #selector(clickStatusItem)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityHelp(
            "Click to open. Right-click for updates, uninstall and quit.")
        if let button = item.button {
            activeDot.frame = NSRect(
                x: button.bounds.midX + 6,
                y: button.isFlipped ? button.bounds.maxY - 8 : 3, width: 5, height: 5)
            activeDot.isHidden = true
            activeDot.wantsLayer = true
            activeDot.layer?.backgroundColor =
                NSColor(srgbRed: 0.85, green: 0.36, blue: 0.04, alpha: 1).cgColor
            activeDot.layer?.cornerRadius = 2.5
            activeDot.setAccessibilityElement(false)
            button.addSubview(activeDot)
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        let host = NSHostingController(rootView: MenuPanel(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        let mainMenu = NSMenu()
        let application = NSMenuItem()
        application.submenu = actionsMenu()
        mainMenu.addItem(application)
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        observePresentation()
    }

    private func observePresentation() {
        withObservationTracking {
            let presentation = model.presentation
            if presentation != lastPresentation {
                lastPresentation = presentation
                activeDot.isHidden = presentation != .active
                statusItem?.button?.setAccessibilityLabel(
                    "Awake: \(presentation?.title ?? "Setup required")")
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePresentation() }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        popover.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        window?.makeFirstResponder(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown,
        ]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    @objc private func clickStatusItem() {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        {
            popover.performClose(nil)
            actionsMenu().popUp(
                positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.animates =
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                && NSApp.currentEvent?.type == .leftMouseUp
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func actionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.appearance = NSApp.effectiveAppearance
        let updates = NSMenuItem(
            title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        let uninstall = NSMenuItem(
            title: "Uninstall Awake…", action: #selector(uninstall), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Awake", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return model.trustedBuild && !model.isPreview && !model.updating
        }
        return menuItem.action != #selector(uninstall)
            || (!model.updating && !model.sudoTouchIDBusy)
    }

    @objc private func checkForUpdates() {
        Task {
            let result = await model.checkForUpdates(manual: true)
            if result == true, model.canInstallAvailableUpdate(manual: true) {
                model.requestUpdate(manual: true)
                return
            }
            let alert = NSAlert()
            alert.messageText = result == true ? "Update available" : "Awake updates"
            alert.informativeText =
                result == true
                ? model.updateInstallBlockMessage(manual: true)
                : result == false
                    ? "Awake is up to date."
                    : model.updateMessage ?? "The next check is available later."
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func uninstall() {
        guard removalWindow == nil else {
            removalWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Uninstall Awake?"
        alert.informativeText =
            "Ends all sessions and removes the helpers, login item and preferences. macOS may ask for separate administrator approvals. Then moves Awake to the Trash. Running commands continue."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.isEnabled = model.trustedBuild && !model.isPreview
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let progress = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
            styleMask: [.titled], backing: .buffered, defer: false)
        progress.title = "Uninstalling Awake"
        progress.isReleasedWhenClosed = false
        progress.contentView = NSHostingView(rootView: RemovalProgress(model: model))
        progress.center()
        progress.makeKeyAndOrderFront(nil)
        removalWindow = progress
        Task {
            while model.busy { try? await Task.sleep(for: .milliseconds(50)) }
            defer {
                progress.close()
                removalWindow = nil
            }
            let identity: SignedIdentity
            do {
                identity = try await SignedIdentity.current(
                    expectedIdentifier: AwakeIdentity.application)
                _ = try await GitHubUpdate.currentInstalledApplication(identity: identity)
            } catch {
                progress.orderOut(nil)
                model.message =
                    "The matching signed Awake.app could not be verified in Applications. Keep it installed there and retry."
                showRemovalError()
                return
            }
            guard await model.removeIntegration() else {
                progress.orderOut(nil)
                showRemovalError()
                return
            }
            let installedApp: URL
            do {
                installedApp = try await GitHubUpdate.currentInstalledApplication(
                    identity: identity)
            } catch {
                progress.orderOut(nil)
                model.message =
                    "The helpers were removed, but the matching signed app in Applications could not be verified. Keep Awake open and inspect the installation."
                showRemovalError()
                return
            }
            do {
                _ = try await NSWorkspace.shared.recycle([installedApp])
                progress.orderOut(nil)
                NSApp.terminate(nil)
            } catch {
                progress.orderOut(nil)
                model.message =
                    "Helper, login item and preferences removed. macOS could not move the app to the Trash: \(error.localizedDescription)"
                NSWorkspace.shared.activateFileViewerSelecting([installedApp])
                showRemovalError()
            }
        }
    }

    private func showRemovalError() {
        let alert = NSAlert()
        alert.messageText = "Uninstall incomplete"
        alert.informativeText = model.message ?? "Keep Awake installed and retry."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.removalComplete { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        let quitEvent = NSAppleEventManager.shared().currentAppleEvent
        terminating = true
        Task {
            if !model.isPreview && Self.isSystemRestart(quitEvent) {
                await model.refresh()
                let remaining =
                    model.status?.sessions.filter { $0.suspension == nil }
                    .map { model.remainingSeconds($0) } ?? []
                if Self.shouldDeferRestart(
                    presentation: model.presentation, remainingSessions: remaining)
                {
                    model.message = "Restart postponed. Stop Awake before restarting your Mac."
                    terminating = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            let restored = await model.prepareToQuit()
            var shouldQuit = restored
            if !restored {
                let alert = NSAlert()
                alert.messageText = "Power restoration is not confirmed"
                alert.informativeText =
                    "Keep Awake open to retry. Quitting leaves the current power state unresolved."
                alert.addButton(withTitle: "Keep Open")
                alert.addButton(withTitle: "Quit Anyway")
                shouldQuit = alert.runModal() == .alertSecondButtonReturn
            }
            terminating = false
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    static func isSystemRestart(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
            event.eventID == AEEventID(kAEQuitApplication),
            let reason = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        return reason == OSType(kAERestart) || reason == OSType(kAEShutDown)
    }

    static func shouldDeferRestart(
        presentation: PowerPresentation?, remainingSessions: [TimeInterval?]
    ) -> Bool {
        presentation == .active && remainingSessions.contains { $0 == nil || $0! > 0 }
    }
}

private struct RemovalProgress: View {
    @Bindable var model: AppModel
    var body: some View {
        ProgressView { Text(model.removalStep ?? "Preparing…") }
            .padding(24).frame(width: 340, height: 110)
    }
}

private final class StatusDot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
