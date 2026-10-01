import Foundation
import Security

let home = FileManager.default.homeDirectoryForCurrentUser
let loginPath = home.appendingPathComponent("Library/Keychains/login.keychain-db").path
let releasePath = home.appendingPathComponent(
    "Library/Keychains/awake-release-signing.keychain-db"
).path
let service = "io.github.oviron.Awake.release-keychain.native"
let account = "Awake Release Native"

var login: SecKeychain?
guard loginPath.withCString({ SecKeychainOpen($0, &login) }) == errSecSuccess, let login else {
    fputs("Cannot open the login keychain.\n", stderr)
    exit(1)
}

var length: UInt32 = 0
var password: UnsafeMutableRawPointer?
let lookup = service.withCString { servicePointer in
    account.withCString { accountPointer in
        SecKeychainFindGenericPassword(
            login, UInt32(service.utf8.count), servicePointer,
            UInt32(account.utf8.count), accountPointer,
            &length, &password, nil)
    }
}
guard lookup == errSecSuccess, let password else {
    fputs("Cannot read the release keychain credential from login.\n", stderr)
    exit(1)
}
defer { SecKeychainItemFreeContent(nil, password) }

var release: SecKeychain?
guard releasePath.withCString({ SecKeychainOpen($0, &release) }) == errSecSuccess,
    let release
else {
    fputs("Cannot open the verified release keychain.\n", stderr)
    exit(1)
}
guard SecKeychainUnlock(release, length, password, true) == errSecSuccess else {
    fputs("Cannot unlock the verified release keychain.\n", stderr)
    exit(1)
}
print("Verified release keychain unlocked.")
