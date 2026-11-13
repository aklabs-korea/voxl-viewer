import Foundation
import UIKit
import WebKit

/// voxl's password (HTTP Basic), for a voxl that keeps one: the one given earlier in this run (the
/// page's socket asks separately), else the Keychain's, else the app asks. As in the Mac app.
enum Password {
    /// Given while the app runs, by scheme, host and port.
    static var signedIn: [String: URLCredential] = [:]

    static func key(_ s: URLProtectionSpace) -> String { "\(s.protocol ?? "")://\(s.host):\(s.port)" }

    static func query(_ s: URLProtectionSpace) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: s.host,
         kSecAttrPort as String: s.port,
         kSecAttrProtocol as String: s.protocol == "https" ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
         kSecAttrLabel as String: "voxl viewer (\(s.host):\(s.port))"]
    }

    static func saved(_ s: URLProtectionSpace) -> URLCredential? {
        var q = query(s)
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let item = out as? [String: Any], let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return URLCredential(user: item[kSecAttrAccount as String] as? String ?? "", password: password, persistence: .forSession)
    }

    static func save(_ s: URLProtectionSpace, _ c: URLCredential) {
        SecItemDelete(query(s) as CFDictionary)
        var q = query(s)
        q[kSecAttrAccount as String] = c.user ?? ""
        q[kSecValueData as String] = Data((c.password ?? "").utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    /// Answers a challenge: a known password at once, else the sign-in sheet over host.
    static func answer(_ ch: URLAuthenticationChallenge, over host: UIViewController, name: String,
                       done: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = ch.protectionSpace
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
               NSURLAuthenticationMethodDefault].contains(space.authenticationMethod) else {
            return done(.performDefaultHandling, nil)
        }
        if ch.previousFailureCount == 0, let c = signedIn[key(space)] ?? saved(space) {
            signedIn[key(space)] = c
            return done(.useCredential, c)
        }
        signedIn[key(space)] = nil
        let a = UIAlertController(title: "Sign in to \(name)",
                                  message: ch.previousFailureCount > 0 ? "That password didn't work. Try again."
                                      : "voxl at \(space.host) asks for its password.",
                                  preferredStyle: .alert)
        a.addTextField { f in
            f.placeholder = "User name (optional)"
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
        }
        a.addTextField { f in
            f.placeholder = "Password"
            f.isSecureTextEntry = true
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(.cancelAuthenticationChallenge, nil) })
        a.addAction(UIAlertAction(title: "Sign In", style: .default) { _ in
            let c = URLCredential(user: a.textFields?[0].text ?? "", password: a.textFields?[1].text ?? "",
                                  persistence: .forSession)
            save(space, c)
            signedIn[key(space)] = c
            done(.useCredential, c)
        })
        (host.presentedViewController ?? host).present(a, animated: true)
    }
}
