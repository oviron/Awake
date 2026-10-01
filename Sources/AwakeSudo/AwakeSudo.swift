import AppKit
import AwakeSystem

@main
@MainActor
struct AwakeSudo {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["--register"] || arguments == ["--unregister"] else {
            let alert = NSAlert()
            alert.messageText = "Touch ID for sudo"
            alert.informativeText =
                "Open Awake and use the Touch ID for sudo switch to set up this component."
            alert.runModal()
            return
        }
        Task {
            do {
                try await SudoInstallation.configure(register: arguments == ["--register"])
            } catch {
                let alert = NSAlert()
                alert.messageText = "Sudo setup was not completed"
                alert.informativeText =
                    "Complete the macOS administrator approval, then retry in Awake."
                alert.alertStyle = .warning
                app.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            app.terminate(nil)
        }
        app.run()
    }
}
