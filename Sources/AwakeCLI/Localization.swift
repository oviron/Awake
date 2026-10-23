import Foundation

extension Bundle {
    /// The Awake.app holding this command, also when it runs through the /usr/local/bin link.
    static let awake: Bundle = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return .main
        }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard app.pathExtension == "app", let bundle = Bundle(url: app) else { return .main }
        return bundle
    }()
}
