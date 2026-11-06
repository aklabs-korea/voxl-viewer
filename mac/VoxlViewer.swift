// voxl viewer for the Mac: shows a machine's voxl page in its own window, in Safari's engine
// (WKWebView) instead of a browser tab.
//
// Why not a tab: browsers keep Cmd+W, Cmd+T, Cmd+R and friends for themselves. Here every Cmd
// shortcut goes to the remote machine (voxl turns the Mac's Cmd into Control on a PC), except
// the viewer's own Cmd+Q and Ctrl+Cmd+F. macOS still keeps Cmd+Tab and Cmd+Space, as for any app.
//
// Which machine opens: a URL argument (open -a "voxl viewer" --args URL [NAME]), else VoxlURL in
// Info.plist (set by mac/make-shortcut.sh), else the last machine used from the Machines menu.
import AppKit
import WebKit

/// The general app's bundle id. Shortcut copies have their own ids but share its machine list.
let mainBundleID = "io.github.danyeoakl.voxl-viewer"
let defaults = Bundle.main.bundleIdentifier == mainBundleID
    ? UserDefaults.standard : UserDefaults(suiteName: mainBundleID) ?? .standard
let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "voxl viewer"
let env = ProcessInfo.processInfo.environment
let selfTesting = env["VOXL_VIEWER_SELFTEST"] != nil
/// Passwords given while the app runs, by scheme, host and port.
var signedIn: [String: URLCredential] = [:]

struct Machine {
    var name: String
    var url: URL

    /// The Machines menu, kept as [{name, url}] in the app's defaults.
    static var saved: [Machine] {
        get {
            (defaults.array(forKey: "machines") as? [[String: String]] ?? []).compactMap {
                guard let name = $0["name"], let url = $0["url"].flatMap(voxlURL) else { return nil }
                return Machine(name: name, url: url)
            }
        }
        set { defaults.set(newValue.map { ["name": $0.name, "url": $0.url.absoluteString] }, forKey: "machines") }
    }

    var isSaved: Bool { Machine.saved.contains { $0.url == url } }
}

/// An http or https URL with a host, or nil. An empty path becomes "/".
func voxlURL(_ text: String) -> URL? {
    guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
          ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host?.isEmpty == false
    else { return nil }
    if c.path.isEmpty { c.path = "/" }
    return c.url
}

/// The URL without a ?token=, which is voxl's password, for names that end up on disk. Other query
/// options stay, so machines that differ only in those keep apart.
func withoutToken(_ url: URL) -> String {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = c.queryItems else {
        return url.absoluteString
    }
    let kept = items.filter { $0.name != "token" }
    c.queryItems = kept.isEmpty ? nil : kept
    return c.url?.absoluteString ?? url.absoluteString
}

/// Whether a frame comes from the machine's own voxl: same scheme, host (in any case) and port.
func isOrigin(_ o: WKSecurityOrigin, of url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    let port = url.port ?? (scheme == "https" ? 443 : 80)
    return o.protocol.lowercased() == scheme && o.host.lowercased() == url.host?.lowercased()
        && (o.port == 0 ? (o.protocol.lowercased() == "https" ? 443 : 80) : o.port) == port
}

/// voxl passwords, saved in the login Keychain per host, port and scheme.
enum Keychain {
    static func query(_ s: URLProtectionSpace) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: s.host,
         kSecAttrPort as String: s.port,
         kSecAttrProtocol as String: s.protocol == "https" ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
         kSecAttrLabel as String: "voxl viewer (\(s.host):\(s.port))"]
    }

    static func find(_ s: URLProtectionSpace) -> (user: String, password: String)? {
        var q = query(s)
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let item = out as? [String: Any], let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return (item[kSecAttrAccount as String] as? String ?? "", password)
    }

    /// The saved user name only. Reading attributes never makes macOS ask for the login password.
    static func user(_ s: URLProtectionSpace) -> String? {
        var q = query(s)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return (out as? [String: Any])?[kSecAttrAccount as String] as? String
    }

    static func save(_ s: URLProtectionSpace, user: String, password: String) {
        SecItemDelete(query(s) as CFDictionary)
        var q = query(s)
        q[kSecAttrAccount as String] = user
        q[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Lets the page have every Cmd shortcut except the viewer's own. WebKit hands a key equivalent to
/// the page first, and voxl's page claims all of them for the remote machine (Cmd+V included,
/// once the Edit menu's Paste has delivered the Mac's clipboard to it).
final class ViewerWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == [.command], key == "q" {
            NSApp.terminate(nil)
            return true
        }
        if mods == [.command, .control], key == "f" {
            window?.toggleFullScreen(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One machine's window. It is the window's delegate, so the View menu's items reach it.
final class MachineWindow: NSObject, NSWindowDelegate, NSMenuItemValidation, WKNavigationDelegate,
                           WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    var machine: Machine {
        didSet {
            window.title = machine.name
            if machine.url != oldValue.url {
                window.setFrameAutosaveName("voxl " + withoutToken(machine.url))
                load()
            }
        }
    }
    let window: NSWindow
    let config = WKWebViewConfiguration()
    var web: ViewerWebView!
    let onClose: (MachineWindow) -> Void
    var stats = false
    var retryLater: DispatchWorkItem?
    /// The remote's latest copy that arrived while the window was in the background.
    var heldClip: Any?
    var resignedKey = Date.distantPast
    /// The Mac clipboard's change count when the window left, or after the viewer's own last write:
    /// any other count means something was copied on the Mac since.
    var ownChange = 0

    init(machine: Machine, onClose: @escaping (MachineWindow) -> Void) {
        self.machine = machine
        self.onClose = onClose
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1600, height: 1000)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: screen.width * 0.8, height: screen.height * 0.8),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        config.mediaTypesRequiringUserActionForPlayback = []
        // Safari only lets a page write the clipboard during a click or key press, and voxl writes it
        // when the remote machine's clipboard changes (Cmd+C there). So the page's writes, text or
        // an image, come here.
        let bridge = """
        (() => {
          const clip = navigator.clipboard;
          if (!clip) return;
          const post = (m) => window.webkit.messageHandlers.clip.postMessage(m);
          clip.writeText = async (t) => post(String(t));
          const write = clip.write ? clip.write.bind(clip) : null;
          clip.write = async (items) => {
            for (const item of items) {
              if (item.types.includes('text/plain'))
                return post(await (await item.getType('text/plain')).text());
              if (item.types.includes('image/png')) {
                const blob = await item.getType('image/png');
                const url = await new Promise((done) => {
                  const r = new FileReader();
                  r.onload = () => done(String(r.result));
                  r.readAsDataURL(blob);
                });
                return post({ png: url.slice(url.indexOf(',') + 1) });
              }
            }
            if (write) return write(items);
          };
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "clip")

        newWebView()
        window.isReleasedWhenClosed = false
        window.title = machine.name
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("voxl " + withoutToken(machine.url))
        window.makeKeyAndOrderFront(nil)
        load()
    }

    func newWebView() {
        web = ViewerWebView(frame: window.contentView?.bounds ?? .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        window.contentView = web
        window.makeFirstResponder(web)
    }

    func load() {
        retryLater?.cancel()
        var url = machine.url
        if stats, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Keep any ?token= as it was typed.
            c.percentEncodedQueryItems = (c.percentEncodedQueryItems ?? []) + [URLQueryItem(name: "stats", value: nil)]
            url = c.url ?? url
        }
        // Going to another URL would keep the old page, and its stream, running in WebKit's
        // back-forward cache. A new web view drops it.
        if web.url != nil, web.url != url { newWebView() }
        web.load(URLRequest(url: url))
    }

    // The remote machine is offline or voxl restarts: try again (voxl's page reconnects on its own
    // once it has loaded).
    func retry(_ why: String) {
        window.subtitle = why + " Trying again…"
        let work = DispatchWorkItem { [weak self] in self?.load() }
        retryLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func failed(_ error: Error) {
        let e = error as NSError
        // Cancelled loads and downloads end here too; only network errors are worth a retry.
        guard e.domain == NSURLErrorDomain, e.code != NSURLErrorCancelled,
              e.code != NSURLErrorUserCancelledAuthentication else { return }
        retry(e.localizedDescription)
    }

    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { failed(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { failed(e) }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { window.subtitle = "" }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { load() }

    // voxl's Files panel downloads with <a download> and attachment responses; a proxy in front of
    // voxl may answer 502 while voxl restarts, which WebKit would show as a finished page.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler done: @escaping (WKNavigationActionPolicy) -> Void) {
        done(a.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse,
                 decisionHandler done: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = r.response as? HTTPURLResponse
        if r.isForMainFrame, let code = http?.statusCode, code >= 500 {
            done(.cancel)
            retry("voxl answered \(code).")
            return
        }
        let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        done(attachment || !r.canShowMIMEType ? .download : .allow)
    }

    func webView(_ w: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }

    /// Into ~/Downloads, as a browser would, without overwriting anything there.
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String,
                  completionHandler done: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        done(url)
    }

    /// The file pickers behind voxl's Upload and Upload folder buttons.
    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo,
                 completionHandler done: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = p.allowsMultipleSelection
        panel.canChooseDirectories = p.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { r in done(r == .OK ? panel.urls : nil) }
    }

    /// voxl's password (HTTP Basic). WKWebView shows no prompt of its own, so: the password given
    /// earlier in this run (the page's socket asks separately), else the Keychain's, else ask.
    func webView(_ w: WKWebView, didReceive ch: URLAuthenticationChallenge,
                 completionHandler done: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = ch.protectionSpace
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
               NSURLAuthenticationMethodDefault].contains(space.authenticationMethod) else {
            return done(.performDefaultHandling, nil)
        }
        let key = "\(space.protocol ?? "")://\(space.host):\(space.port)"
        if ch.previousFailureCount == 0, let c = signedIn[key] ?? Keychain.find(space).map({
            URLCredential(user: $0.user, password: $0.password, persistence: .forSession)
        }) {
            signedIn[key] = c
            return done(.useCredential, c)
        }
        signedIn[key] = nil
        askPassword(space, wrong: ch.previousFailureCount > 0) { a in
            guard let a else {
                // Show voxl's 401 page; View > Reload asks again.
                return done(.performDefaultHandling, nil)
            }
            if a.save { Keychain.save(space, user: a.user, password: a.password) }
            let c = URLCredential(user: a.user, password: a.password, persistence: .forSession)
            signedIn[key] = c
            done(.useCredential, c)
        }
    }

    func askPassword(_ space: URLProtectionSpace, wrong: Bool,
                     answer: @escaping ((user: String, password: String, save: Bool)?) -> Void) {
        if selfTesting, let password = env["VOXL_VIEWER_SELFTEST_PASSWORD"] {
            return answer(wrong ? nil : ("", password, true))
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(machine.name)"
        alert.informativeText = wrong ? "That password didn't work. Try again."
            : "voxl at \(space.host) asks for its password."
        let user = NSTextField(frame: NSRect(x: 0, y: 54, width: 280, height: 22))
        user.placeholderString = "User name (optional)"
        user.stringValue = Keychain.user(space) ?? ""
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 26, width: 280, height: 22))
        password.placeholderString = "Password"
        let save = NSButton(checkboxWithTitle: "Save in Keychain", target: nil, action: nil)
        save.frame = NSRect(x: 0, y: 0, width: 280, height: 18)
        save.state = .on
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 76))
        [user, password, save].forEach(box.addSubview)
        user.nextKeyView = password
        password.nextKeyView = user
        alert.accessoryView = box
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = password
        alert.beginSheetModal(for: window) { r in
            answer(r == .alertFirstButtonReturn
                ? (user.stringValue, password.stringValue, save.state == .on) : nil)
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        // Only voxl's own page may write the Mac's clipboard.
        guard m.name == "clip", isOrigin(m.frameInfo.securityOrigin, of: machine.url) else { return }
        // In front: write it. In the background, a copy on the Mac since the window left always wins;
        // otherwise write it now if the window only just left (Cmd+C on the remote, then Cmd+Tab),
        // or when it comes back.
        if window.isKeyWindow {
            writeClipboard(m.body)
        } else if NSPasteboard.general.changeCount != ownChange {
            heldClip = nil
        } else if Date().timeIntervalSince(resignedKey) < 1 {
            writeClipboard(m.body)
        } else {
            heldClip = m.body
        }
    }

    func windowDidResignKey(_ note: Notification) {
        resignedKey = Date()
        ownChange = NSPasteboard.general.changeCount
    }

    func windowDidBecomeKey(_ note: Notification) {
        if let held = heldClip, NSPasteboard.general.changeCount == ownChange { writeClipboard(held) }
        heldClip = nil
    }

    func writeClipboard(_ body: Any) {
        let board = NSPasteboard.general
        if let text = body as? String {
            board.clearContents()
            board.setString(text, forType: .string)
        } else if let png = (body as? [String: Any])?["png"] as? String, let data = Data(base64Encoded: png) {
            board.clearContents()
            board.setData(data, forType: .png)
        }
        ownChange = board.changeCount
    }

    func windowWillClose(_ note: Notification) {
        // Let the web view go, so the stream stops with the window.
        retryLater?.cancel()
        config.userContentController.removeScriptMessageHandler(forName: "clip")
        onClose(self)
    }

    @objc func reloadMachine(_ sender: Any?) { load() }
    @objc func toggleVoxlStats(_ sender: Any?) { stats.toggle(); load() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleVoxlStats(_:)) { item.state = stats ? .on : .off }
        return true
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var windows: [MachineWindow] = []
    var selfTestFailed = false

    /// The machine in front.
    var current: MachineWindow? { windows.first { $0.window == NSApp.mainWindow } }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        if let m = launchMachine() ?? lastMachine() {
            open(m)
        } else {
            addMachine(nil)
        }
        if windows.isEmpty { return NSApp.terminate(nil) }
        NSApp.activate()
        if selfTesting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.selfTest() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// A URL argument (and an optional name after it), else this bundle's VoxlURL.
    func launchMachine() -> Machine? {
        let args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(where: { voxlURL($0) != nil }), let url = voxlURL(args[i]) {
            let given = args.indices.contains(i + 1) && !args[i + 1].hasPrefix("-") ? args[i + 1] : nil
            return Machine(name: given ?? Machine.saved.first { $0.url == url }?.name ?? url.host!, url: url)
        }
        if let url = (Bundle.main.infoDictionary?["VoxlURL"] as? String).flatMap(voxlURL) {
            return Machine(name: appName, url: url)
        }
        return nil
    }

    func lastMachine() -> Machine? {
        let saved = Machine.saved
        return saved.first { $0.url.absoluteString == defaults.string(forKey: "lastURL") } ?? saved.first
    }

    func open(_ m: Machine) {
        if let w = windows.first(where: { $0.machine.url == m.url }) {
            return w.window.makeKeyAndOrderFront(nil)
        }
        windows.append(MachineWindow(machine: m) { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        })
        if m.isSaved { defaults.set(m.url.absoluteString, forKey: "lastURL") }
    }

    @objc func openMachine(_ item: NSMenuItem) {
        if let m = Machine.saved.first(where: { $0.url.absoluteString == item.representedObject as? String }) {
            open(m)
        }
    }

    @objc func addMachine(_ sender: Any?) {
        guard case .save(let m) = machineDialog("Add a machine", nil) else { return }
        Machine.saved = Machine.saved.filter { $0.url != m.url } + [m]
        open(m)
    }

    @objc func editMachine(_ sender: Any?) {
        guard let w = current, let i = Machine.saved.firstIndex(where: { $0.url == w.machine.url }) else { return }
        var list = Machine.saved
        switch machineDialog("Edit \(w.machine.name)", list[i]) {
        case .save(let m):
            list[i] = m
            Machine.saved = list
            if defaults.string(forKey: "lastURL") == w.machine.url.absoluteString {
                defaults.set(m.url.absoluteString, forKey: "lastURL")
            }
            w.machine = m
        case .remove:
            list.remove(at: i)
            Machine.saved = list
            if defaults.string(forKey: "lastURL") == w.machine.url.absoluteString {
                defaults.removeObject(forKey: "lastURL")
            }
        case .cancel:
            break
        }
    }

    enum DialogResult { case save(Machine), remove, cancel }

    /// Name and URL, with Remove when editing. Asks again until the URL is a usable one.
    func machineDialog(_ title: String, _ start: Machine?) -> DialogResult {
        var note = "A name for the Machines menu, and the address of the machine's voxl page."
        var name = start?.name ?? "", url = start?.url.absoluteString ?? ""
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = note
            let nameField = NSTextField(frame: NSRect(x: 80, y: 30, width: 300, height: 22))
            nameField.stringValue = name
            nameField.placeholderString = "My Mac"
            let urlField = NSTextField(frame: NSRect(x: 80, y: 0, width: 300, height: 22))
            urlField.stringValue = url
            urlField.placeholderString = "https://my-mac.example.ts.net:6901/"
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 52))
            for (text, y) in [("Name:", 33), ("voxl URL:", 3)] {
                let label = NSTextField(labelWithString: text)
                label.frame = NSRect(x: 0, y: y, width: 74, height: 17)
                label.alignment = .right
                box.addSubview(label)
            }
            box.addSubview(nameField)
            box.addSubview(urlField)
            nameField.nextKeyView = urlField
            urlField.nextKeyView = nameField
            alert.accessoryView = box
            alert.addButton(withTitle: start == nil ? "Add" : "Save")
            alert.addButton(withTitle: "Cancel")
            if start != nil { alert.addButton(withTitle: "Remove").hasDestructiveAction = true }
            alert.window.initialFirstResponder = nameField
            let r = alert.runModal()
            name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            switch r {
            case .alertFirstButtonReturn:
                guard let u = voxlURL(url) else {
                    note = "Enter the whole address, starting with https:// or http://."
                    continue
                }
                if u != start?.url, let other = Machine.saved.first(where: { $0.url == u }) {
                    note = "That address is already saved as \"\(other.name)\"."
                    continue
                }
                return .save(Machine(name: name.isEmpty ? u.host! : name, url: u))
            case .alertThirdButtonReturn:
                return .remove
            default:
                return .cancel
            }
        }
    }

    // The Machines menu is rebuilt each time it opens, so every app copy shows the current list.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for m in Machine.saved {
            let item = NSMenuItem(title: m.name, action: #selector(openMachine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.url.absoluteString
            item.state = current?.machine.url == m.url ? .on : .off
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for (title, action) in [("Add Machine…", #selector(addMachine(_:))),
                                ("Edit or Remove Machine…", #selector(editMachine(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(editMachine(_:)) { return current?.machine.isSaved ?? false }
        return true
    }

    func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let holder = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            holder.submenu = m
            main.addItem(holder)
            return m
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        _ = menu(appName, [item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")])
        menu("Machines", []).delegate = self
        // Paste is how the page gets the Mac's clipboard: voxl copies it to the remote machine, then
        // presses its paste shortcut there. Cut, Copy and Select All only act where voxl's page lets
        // a key through (the dialogs here); everything else goes to the remote machine.
        _ = menu("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = menu("View", [
            item("Reload", #selector(MachineWindow.reloadMachine(_:))),
            item("Show voxl's stats", #selector(MachineWindow.toggleVoxlStats(_:))),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        NSApp.windowsMenu = menu("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)))])
        NSApp.mainMenu = main
    }

    func check(_ what: String, _ ok: Bool, _ detail: Any = "") {
        print(ok ? "ok  " : "FAIL", what, detail)
        if !ok { selfTestFailed = true }
    }

    /// VOXL_VIEWER_SELFTEST=1 with a URL argument (point it at a --read-only voxl): checks the page
    /// connected, presses Cmd+W, Cmd+T, Cmd+L and Cmd+V as a user would, writes the clipboard from
    /// the page, downloads a file, prints what arrived and quits, with status 1 if anything failed.
    /// It overwrites the Mac's clipboard. VOXL_VIEWER_SELFTEST_PASSWORD answers voxl's password
    /// prompt once (and saves it in the Keychain, as a user who leaves Save ticked), then cancels.
    func selfTest() {
        guard let w = windows.first else { return }
        let recorder = """
        window.__keys = []; window.__pastes = [];
        addEventListener('keydown', e => __keys.push((e.metaKey ? 'cmd+' : '') + e.key), true);
        addEventListener('paste', e => __pastes.push(e.clipboardData.getData('text/plain')), true);
        (document.querySelector('textarea') || document.body).focus();
        document.getElementById('status')?.style.display === 'none'
        """
        w.web.evaluateJavaScript(recorder) { r, _ in
            self.check("page connected to voxl", r as? Bool == true)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("from-the-mac", forType: .string)
            for ch in ["w", "t", "l", "v"] {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.command],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.window.windowNumber, context: nil,
                                                characters: ch, charactersIgnoringModifiers: ch,
                                                isARepeat: false, keyCode: ["w": 13, "t": 17, "l": 37, "v": 9][ch]!) {
                        NSApp.sendEvent(e)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                w.web.evaluateJavaScript("navigator.clipboard.writeText('from-the-page'), 'sent'") { _, _ in }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    w.web.evaluateJavaScript("JSON.stringify({keys: __keys, pastes: __pastes})") { r, _ in
                        let got = r as? String ?? ""
                        self.check("Cmd+W, T, L, V reached the page", ["cmd+w", "cmd+t", "cmd+l", "cmd+v"]
                            .allSatisfy { got.contains("\"\($0)\"") }, got)
                        self.check("Edit > Paste gave the page the Mac's clipboard", got.contains("from-the-mac"))
                        self.check("window still open after Cmd+W", w.window.isVisible)
                        let text = NSPasteboard.general.string(forType: .string)
                        self.check("page's clipboard text reached the Mac", text == "from-the-page", text ?? "nil")
                        // An image copied on the remote machine, and a download from the Files panel.
                        let image = """
                        fetch('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
                          .then(r => r.blob()).then(b => navigator.clipboard.write([new ClipboardItem({'image/png': b})]));
                        const a = document.createElement('a');
                        a.href = URL.createObjectURL(new Blob(['voxl viewer self-test'], {type: 'text/plain'}));
                        a.download = 'voxl-viewer-selftest.txt';
                        document.body.appendChild(a); a.click(); 'sent'
                        """
                        w.web.evaluateJavaScript(image) { _, _ in }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self.check("page's clipboard image reached the Mac",
                                       NSPasteboard.general.data(forType: .png) != nil)
                            let file = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("voxl-viewer-selftest.txt")
                            let saved = try? String(contentsOf: file, encoding: .utf8)
                            self.check("download saved in ~/Downloads", saved == "voxl viewer self-test")
                            try? FileManager.default.removeItem(at: file)
                            print(self.selfTestFailed ? "self-test FAILED" : "self-test passed")
                            exit(self.selfTestFailed ? 1 : 0)
                        }
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
let viewer = App()
app.delegate = viewer
app.setActivationPolicy(.regular)
app.run()
