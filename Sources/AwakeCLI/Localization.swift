import Foundation

extension Bundle {
    /// The strings of Awake.app in the user's language, also when the command runs through
    /// the /usr/local/bin link. That link's directory becomes the main bundle, which has no
    /// localizations, so Foundation would fall back to English for any other bundle.
    static let awake: Bundle = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return .main
        }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard app.pathExtension == "app", let bundle = Bundle(url: app) else { return .main }
        let language = Bundle.preferredLocalizations(
            from: bundle.localizations, forPreferences: Locale.preferredLanguages
        ).first
        return language.flatMap { bundle.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:)) ?? bundle
    }()
}
