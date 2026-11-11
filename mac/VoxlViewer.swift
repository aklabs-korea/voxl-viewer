// voxl viewer for the Mac: shows a machine's voxl page in its own window, in Safari's engine
// (WKWebView) instead of a browser tab.
//
// Why not a tab: browsers keep Cmd+W, Cmd+T, Cmd+R and friends for themselves. Here every Cmd
// shortcut goes to the remote machine (voxl turns the Mac's Cmd into Control on a PC), except
// the viewer's own Cmd+Q and Ctrl+Cmd+F. macOS still keeps Cmd+Tab and Cmd+Space, as for any app.
//
// A machine has one or more screens, each its own voxl URL, in the user's order. Its window shows
// one at a time: F1..F9, the tab row under the title bar, or (in full screen) the tab at an edge
// of the picture, switch between them.
//
// Which machine opens: a URL argument (open -a "voxl viewer" --args URL [NAME]), else VoxlURL in
// Info.plist (set by mac/make-shortcut.sh), else the last machine used from the Machines menu. A
// URL opens the saved machine that has a screen there, at its first screen.
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

// Saved settings, in the general app's defaults (every launcher shares them):
//   machineList  [{id, name, screens: [{name, url, sharp}]}]: each machine's screens in the user's
//                order (the first opens with the window; up to nine). sharp, a smaller stream of
//                the same screen, is optional, and so is id (filled in when first read).
//   sharp        true for Sharp: each screen's sharp URL, on machines where every screen has one.
//   edge         where the switcher's tab is: top (the default), left, bottom or right.
//   lastMachine  the id of the machine opened last.
// Older versions kept machines [{name, url}]. It is read once into machineList, as machines with
// one screen of the same name, and left as it was for older copies of the app. To seed a machine:
//   defaults write io.github.danyeoakl.voxl-viewer machineList -array '<dict>
//     <key>name</key><string>M3</string><key>screens</key><array>
//     <dict><key>name</key><string>bottom</string><key>url</key><string>https://m3.example.ts.net:6901/</string>
//     <key>sharp</key><string>https://m3.example.ts.net:6903/</string></dict></array></dict>'

/// One of a machine's screens. sharp is a smaller stream of the same screen, if it has one.
struct Screen: Equatable {
    var name: String
    var url: URL
    var sharp: URL?
}

struct Machine: Equatable {
    static let maxScreens = 9
    var id: String
    var name: String
    var screens: [Screen]

    /// Whether Full | Sharp applies to it: every screen has a Sharp URL.
    var hasSharp: Bool { screens.allSatisfy { $0.sharp != nil } }
    /// Whether a launch URL opens this machine: one of its screens, with or without a ?token=, or the
    /// first screen it was saved with (its id). A machine made from that URL alone would take the
    /// same id, and its first edit would overwrite this one.
    func owns(_ url: URL) -> Bool { has(url) || id == withoutToken(url) }
    /// Whether url is one of its screens now, Full or Sharp, with or without a ?token=.
    func has(_ url: URL) -> Bool {
        let bare = withoutToken(url)
        return screens.contains { withoutToken($0.url) == bare || $0.sharp.map(withoutToken) == bare }
    }
    var isSaved: Bool { Machine.saved.contains { $0.id == id } }

    /// The Machines menu. A one-URL machine (the old list, or a seed without screens) becomes a
    /// machine with one screen, and the list is written back once in today's shape.
    static var saved: [Machine] {
        let current = defaults.array(forKey: "machineList")
        var rewrite = current == nil
        let list = (current ?? defaults.array(forKey: "machines") ?? []).compactMap { item -> Machine? in
            guard let d = item as? [String: Any], let name = d["name"] as? String else { return nil }
            let screens = (d["screens"] as? [Any] ?? [d]).compactMap { item -> Screen? in
                guard let s = item as? [String: Any], let url = (s["url"] as? String).flatMap(voxlURL) else { return nil }
                let given = (s["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                return Screen(name: given.isEmpty ? hostPort(url) : given, url: url,
                              sharp: (s["sharp"] as? String).flatMap(voxlURL))
            }
            guard let first = screens.first else { return nil }
            if d["id"] == nil || d["screens"] == nil { rewrite = true }
            // Without an id, the first URL as older versions had it, which also keeps the window's place.
            return Machine(id: d["id"] as? String ?? withoutToken(first.url),
                           name: name.isEmpty ? hostPort(first.url) : name,
                           screens: Array(screens.prefix(maxScreens)))
        }
        if rewrite && !list.isEmpty { store(list) }
        return list
    }

    static func store(_ list: [Machine]) {
        defaults.set(list.map { m -> [String: Any] in
            ["id": m.id, "name": m.name, "screens": m.screens.map { s -> [String: String] in
                var d = ["name": s.name, "url": s.url.absoluteString]
                d["sharp"] = s.sharp?.absoluteString
                return d
            }]
        }, forKey: "machineList")
    }

    /// Saves a machine, in its place or at the end.
    static func keep(_ m: Machine) {
        var list = saved
        if let i = list.firstIndex(where: { $0.id == m.id }) { list[i] = m } else { list.append(m) }
        store(list)
    }

    static func forget(_ id: String) { store(saved.filter { $0.id != id }) }
}

extension Machine {
    /// A URL no saved machine has, as a machine of its own with one screen.
    init(url: URL, name: String) {
        self.init(id: withoutToken(url), name: name, screens: [Screen(name: name, url: url)])
    }
}

/// Where the tab slides out, for every machine.
enum Edge: String, CaseIterable {
    case top, left, bottom, right

    static var chosen: Edge { Edge(rawValue: defaults.string(forKey: "edge") ?? "") ?? .top }
    var title: String { rawValue.capitalized }
    var note: String {
        switch self {
        case .top: return "Shares the edge with the Mac's menu bar."
        case .left: return "Won't stop the pointer if another monitor sits on that side."
        case .bottom: return "Shares the edge with the Dock and, in a window, the Windows taskbar."
        case .right: return "Won't stop the pointer if another monitor sits on that side. voxl's files panel is there too."
        }
    }
}

/// Full or Sharp, for every machine: true loads each screen's Sharp URL.
var sharpChosen: Bool { defaults.bool(forKey: "sharp") }

/// The viewer's key for a screen: F and its number (Fn+F1 ... where the F keys are media keys).
func shortcut(_ row: Int) -> String { "F\(row + 1)" }

/// F1 to F9's key codes, for screens 1 to 9.
let fKeys: [UInt16: Int] = [122: 0, 120: 1, 99: 2, 118: 3, 96: 4, 97: 5, 98: 6, 100: 7, 101: 8]

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

/// "host:port": a new screen's name until voxl's page title arrives, or if it doesn't.
func hostPort(_ url: URL) -> String {
    let host = url.host ?? url.absoluteString
    return url.port.map { "\(host):\($0)" } ?? host
}

/// The machine and row that already have url for a screen, apart from the given screen. also is a
/// machine that may not be saved yet (the one being edited).
func screenUsing(_ url: URL, besides: (id: String, row: Int)? = nil, also: Machine? = nil) -> (machine: Machine, row: Int)? {
    var list = Machine.saved
    if let also {
        list.removeAll { $0.id == also.id }
        list.append(also)
    }
    for m in list {
        for (i, s) in m.screens.enumerated() where s.url == url && !(besides?.id == m.id && besides?.row == i) {
            return (m, i)
        }
    }
    return nil
}

/// voxl's page title (its --title), to name a screen added by its link.
func fetchTitle(_ url: URL, _ done: @escaping (String) -> Void) {
    URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 5)) { data, response, _ in
        guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return }
        let html = String(decoding: data, as: UTF8.self)
        guard let open = html.range(of: "<title>"),
              let close = html.range(of: "</title>", range: open.upperBound..<html.endIndex) else { return }
        var title = String(html[open.upperBound..<close.lowerBound])
        for (code, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            title = title.replacingOccurrences(of: code, with: char)
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // voxl's default title is every screen's: host:port tells them apart.
        if !title.isEmpty, title != "Voxl Computer Stream" { DispatchQueue.main.async { done(title) } }
    }.resume()
}

/// Whether voxl typed this key on this Mac, for someone controlling it from elsewhere. Passed on, it
/// would go to the machine on view, which may be the one it came from, and round again. Only voxl's:
/// Universal Control and remappers also post keys, and those are the user's own.
func typedByVoxl(_ e: NSEvent) -> Bool {
    guard let pid = e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID), pid > 0,
          pid != Int64(getpid()) else { return false }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(Int32(pid), &path, UInt32(path.count)) > 0 else { return false }
    let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
    return name == "voxl" || name == "voxl-1"
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

/// Tells the app when voxl's page has connected (its hello) and when its picture arrives.
let pictureWatch = """
(() => {
  const post = (m) => window.webkit.messageHandlers.viewer.postMessage(m);
  let hello = false, picture = false;
  const seen = () => { if (!picture) { picture = true; post('picture'); } };
  // Where the browser can, voxl shows its picture in <video> stripes...
  addEventListener('playing', seen, true);
  // ...in WebKit it paints in its worker, whose once-a-second stats then count frames.
  const W = window.Worker;
  if (W) window.Worker = class extends W {
    constructor(...args) {
      super(...args);
      this.addEventListener('message', (e) => {
        const m = e.data || {};
        if (m.t === 'hello' && !hello) { hello = true; post('hello'); }
        if (m.t === 'stats' && m.fps > 0) seen();
      });
    }
  };
})();
"""

/// Lets the page have every Cmd shortcut except the viewer's own. WebKit hands a key equivalent to
/// the page first, and voxl's page claims all of them for the remote machine (Cmd+V included,
/// once the Edit menu's Paste has delivered the Mac's clipboard to it).
final class ViewerWebView: WKWebView {
    private var pageMuted: Bool?

    /// Mute the whole page, including its AudioWorklet. Older WebKit can suspend playback instead.
    func mutePage(_ muted: Bool) {
        guard pageMuted != muted else { return }
        pageMuted = muted
        let selector = NSSelectorFromString("_setPageMuted:")
        if responds(to: selector) {
            typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
            let call = unsafeBitCast(method(for: selector), to: SetPageMuted.self)
            call(self, selector, muted ? 1 : 0)
        } else {
            setAllMediaPlaybackSuspended(muted, completionHandler: nil)
        }
    }

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

/// The look of the chip, the tab and the panel: dark and see-through, with round corners.
func backdrop(_ v: NSVisualEffectView, radius: CGFloat) {
    v.material = .hudWindow
    v.blendingMode = .withinWindow
    v.state = .active
    v.appearance = NSAppearance(named: .vibrantDark)
    let side = radius * 2 + 1
    let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    mask.resizingMode = .stretch
    v.maskImage = mask
}

func clamp(_ v: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { max(low, min(v, high)) }

/// The note in the middle of the picture: the screen connecting, or one that isn't answering.
/// Clicks go through it to the remote.
final class Chip: NSVisualEffectView {
    let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        backdrop(self, radius: 10)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        addSubview(label)
        alphaValue = 0
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows text in the middle of the picture, or fades out for nil.
    func show(_ text: String?) {
        if let text, let parent = superview {
            label.stringValue = text
            let size = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 420, height: 1000))
            let w = ceil(size.width), h = ceil(size.height)
            label.frame = NSRect(x: 16, y: 10, width: w, height: h)
            frame = NSRect(x: ((parent.bounds.width - w) / 2 - 16).rounded(),
                           y: ((parent.bounds.height - h) / 2 - 10).rounded(), width: w + 32, height: h + 20)
        }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = text == nil ? 0.4 : 0.15
            animator().alphaValue = text == nil ? 0 : 1
        }
    }
}

/// The edge tab: "N · name" for the screen on view. A click opens the panel.
final class TabView: NSVisualEffectView {
    let label = NSTextField(labelWithString: "")
    var onClick: () -> Void = {}

    init() {
        super.init(frame: .zero)
        backdrop(self, radius: 7)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Says text, and fits to it.
    func say(_ text: String) {
        label.stringValue = text
        let s = label.cell!.cellSize
        let w = min(ceil(s.width), 280)
        label.frame = NSRect(x: 10, y: 4, width: w, height: ceil(s.height))
        setFrameSize(NSSize(width: w + 20, height: ceil(s.height) + 8))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// A line of the panel: a tick, a number, a title and keys. Lit under the pointer; a click acts.
final class PanelRow: NSView {
    let action: () -> Void
    let parts: [NSTextField]
    var lit = false { didSet { needsDisplay = true } }

    init(ticked: Bool, number: String, title: String, keys: String, action: @escaping () -> Void) {
        self.action = action
        parts = [ticked ? "✓" : "", number, title, keys].map { NSTextField(labelWithString: $0) }
        super.init(frame: .zero)
        for p in parts {
            p.font = .systemFont(ofSize: 13)
            p.lineBreakMode = .byTruncatingTail
            addSubview(p)
        }
        parts[3].textColor = .secondaryLabelColor
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The width that shows it all.
    var need: CGFloat { 46 + ceil(parts[2].cell!.cellSize.width) + 24 + ceil(parts[3].cell!.cellSize.width) + 12 }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let keys = ceil(parts[3].cell!.cellSize.width)
        let spans: [(CGFloat, CGFloat)] = [(12, 14), (28, 16), (46, size.width - 46 - 24 - keys - 12),
                                           (size.width - 12 - keys, keys)]
        for (p, (x, w)) in zip(parts, spans) {
            let h = ceil(p.cell!.cellSize.height)
            p.frame = NSRect(x: x, y: ((size.height - h) / 2).rounded(), width: max(0, w), height: h)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard lit else { return }
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { lit = true }
    override func mouseExited(with event: NSEvent) { lit = false }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// The panel the tab opens: the machine's screens, Full | Sharp, Full screen and Settings…
final class PanelView: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        backdrop(self, radius: 9)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// Lays the items out from the top, and fits the panel to them.
    func fill(_ items: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        let width = max(200, items.compactMap { ($0 as? PanelRow)?.need }.max() ?? 0)
        let heights = items.map { item -> CGFloat in
            item is PanelRow ? 24 : item is NSBox ? 9 : item.fittingSize.height + 10
        }
        setFrameSize(NSSize(width: width, height: heights.reduce(12, +)))
        var y = frame.height - 6
        for (item, h) in zip(items, heights) {
            y -= h
            switch item {
            case is PanelRow:
                item.setFrameOrigin(NSPoint(x: 0, y: y))
                item.setFrameSize(NSSize(width: width, height: h))
            case is NSBox: item.frame = NSRect(x: 12, y: y + 4, width: width - 24, height: 1)
            default: item.frame = NSRect(x: 12, y: y + 5, width: width - 24, height: h - 10)
            }
            addSubview(item)
        }
    }
}

/// The edge tab and its panel. They float over the picture without moving or resizing it, and
/// never take the keyboard: typing goes on to the remote machine.
final class Switcher: NSObject {
    unowned let owner: MachineWindow
    let tab = TabView()
    let panel = PanelView()
    /// The edge the tab is at, where it slides back out.
    var edge = Edge.top
    /// How far below the top edge the tab is: in full screen, clear of the menu bar and title bar.
    var drop: CGFloat = 0
    var dwell: (at: NSPoint, work: DispatchWorkItem)?
    /// After a click at the edge, or a tab only parked on: no tab until the pointer leaves the edge.
    var spent = false
    /// While the tab is out: puts it away once the pointer has been away 0.6 s, or parked 3 s.
    var watch: Timer?
    var shownAt = Date.distantPast
    var awaySince: Date?

    init(owner: MachineWindow) {
        self.owner = owner
        super.init()
        tab.onClick = { [weak self] in self?.togglePanel() }
    }

    var content: NSView { owner.content }
    var isShown: Bool { watch != nil }

    /// The pointer, in the picture's coordinates (from the bottom left).
    var pointer: NSPoint { content.convert(owner.window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }

    /// Within 3 px of the edge.
    func atEdge(_ p: NSPoint) -> Bool {
        let b = content.bounds
        guard p.x >= 0, p.y >= 0, p.x <= b.width, p.y <= b.height else { return false }
        switch Edge.chosen {
        case .top: return p.y >= b.height - 3
        case .bottom: return p.y <= 3
        case .left: return p.x <= 3
        case .right: return p.x >= b.width - 3
        }
    }

    /// At the edge, in its middle third: the corners and the rest of the edge stay with the remote.
    func inZone(_ p: NSPoint) -> Bool {
        let b = content.bounds
        switch Edge.chosen {
        case .top, .bottom: return atEdge(p) && p.x >= b.width / 3 && p.x <= b.width * 2 / 3
        case .left, .right: return atEdge(p) && p.y >= b.height / 3 && p.y <= b.height * 2 / 3
        }
    }

    func onTabOrPanel(_ p: NSPoint, margin: CGFloat = 0) -> Bool {
        [tab, panel].contains { $0.superview != nil && $0.frame.insetBy(dx: -margin, dy: -margin).contains(p) }
    }

    /// Every mouse event of the window, before the page or the tab gets it. None stops here: a click
    /// away from the tab and panel puts them away and still goes to the remote.
    func mouse(_ e: NSEvent) {
        // In a window with the tab row, the screens are a click away already.
        guard !owner.tabsShown else { return hide() }
        let p = pointer
        if !atEdge(p) { spent = false }
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // A click at the edge, or a drag let go there, was for the remote.
            cancelDwell()
            if onTabOrPanel(p) { return }
            if atEdge(p) { spent = true }
            hide()
        case .mouseMoved:
            guard !isShown, !spent, inZone(p), NSEvent.pressedMouseButtons == 0 else { return cancelDwell() }
            // Resting: small moves don't start the wait again.
            if let d = dwell, hypot(p.x - d.at.x, p.y - d.at.y) <= 4 { return }
            cancelDwell()
            let work = DispatchWorkItem { [weak self] in self?.dwelt() }
            dwell = (p, work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        default: // a drag
            cancelDwell()
        }
    }

    func cancelDwell() {
        dwell?.work.cancel()
        dwell = nil
    }

    /// The pointer rested 0.4 s: the tab, if it's still there and nothing is held down.
    func dwelt() {
        dwell = nil
        let p = pointer
        guard !isShown, !spent, inZone(p), NSEvent.pressedMouseButtons == 0, owner.window.isKeyWindow,
              NSApp.isActive else { return }
        edge = Edge.chosen
        drop = edge == .top ? topDrop() : 0
        tab.say(owner.label)
        let b = content.bounds, s = tab.frame.size
        let x = clamp(p.x - s.width / 2, 0, b.width - s.width), y = clamp(p.y - s.height / 2, 0, b.height - s.height)
        var to = NSRect(origin: .zero, size: s)
        switch edge {
        case .top: to.origin = NSPoint(x: x, y: b.height - drop - s.height)
        case .bottom: to.origin = NSPoint(x: x, y: 0)
        case .left: to.origin = NSPoint(x: 0, y: y)
        case .right: to.origin = NSPoint(x: b.width - s.width, y: y)
        }
        tab.frame = outside(to)
        content.addSubview(tab)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.15
            tab.animator().frame = to
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.owner.window.invalidateCursorRects(for: self.tab)
        })
        shownAt = Date()
        awaySince = nil
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    /// How far below the top the tab goes. In full screen, macOS's menu bar and the window's title
    /// bar come down over the top of the picture while the pointer is there: just below them.
    func topDrop() -> CGFloat {
        guard owner.window.styleMask.contains(.fullScreen), let screen = owner.window.screen else { return 0 }
        let menu = max(NSApp.mainMenu?.menuBarHeight ?? 0, NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        let title = NSWindow.frameRect(forContentRect: .zero, styleMask: .titled).height
        let below = owner.window.convertPoint(fromScreen: NSPoint(x: 0, y: screen.frame.maxY - menu - title))
        return max(0, content.bounds.height - content.convert(below, from: nil).y) + 4
    }

    /// Just beyond the edge, where the tab slides in from and back out to.
    func outside(_ r: NSRect) -> NSRect {
        let b = content.bounds
        var r = r
        switch edge {
        case .top: r.origin.y = b.height
        case .bottom: r.origin.y = -r.height
        case .left: r.origin.x = -r.width
        case .right: r.origin.x = b.width
        }
        return r
    }

    func tick() {
        guard owner.window.isKeyWindow, NSApp.isActive else { return hide() }
        let p = pointer, t = tab.frame
        // Below the bars in full screen, the strip above the tab, which the pointer crosses to
        // reach it, counts as on it.
        let above = drop > 0 && p.y >= t.maxY && p.x >= t.minX - 8 && p.x <= t.maxX + 8
        if onTabOrPanel(p, margin: 8) || above {
            awaySince = nil
        } else if awaySince == nil {
            awaySince = Date()
        }
        if let a = awaySince, -a.timeIntervalSinceNow >= 0.6 { return hide() }
        // Only parked on, never clicked: it goes, and stays away until the pointer leaves the edge.
        if panel.superview == nil, -shownAt.timeIntervalSinceNow >= 3 {
            spent = true
            hide()
        }
    }

    /// The tab was clicked: the panel opens inward from it, or closes.
    func togglePanel() {
        if panel.superview != nil {
            panel.removeFromSuperview()
            shownAt = Date()
            return
        }
        let w = owner
        var items: [NSView] = w.machine.screens.indices.map { i in
            PanelRow(ticked: i == w.row, number: "\(i + 1)", title: w.machine.screens[i].name, keys: shortcut(i)) {
                [weak self] in
                self?.hide()
                self?.owner.choose(i)
            }
        }
        let line = NSBox()
        line.boxType = .separator
        items.append(line)
        if w.machine.hasSharp {
            let pick = NSSegmentedControl(labels: ["Full", "Sharp"], trackingMode: .selectOne, target: self,
                                          action: #selector(pickSharp(_:)))
            pick.selectedSegment = sharpChosen ? 1 : 0
            pick.segmentDistribution = .fillEqually
            pick.refusesFirstResponder = true
            items.append(pick)
        }
        let full = w.window.styleMask.contains(.fullScreen)
        items.append(PanelRow(ticked: false, number: "", title: full ? "Leave full screen" : "Full screen",
                              keys: "⌃⌘F") { [weak self] in
            self?.hide()
            self?.owner.window.toggleFullScreen(nil)
        })
        items.append(PanelRow(ticked: false, number: "", title: "Settings…", keys: "") { [weak self] in
            self?.hide()
            self?.owner.openSettings(nil)
        })
        panel.fill(items)
        let b = content.bounds, t = tab.frame, s = panel.frame.size
        var o: NSPoint
        switch edge {
        case .top: o = NSPoint(x: t.midX - s.width / 2, y: t.minY - 4 - s.height)
        case .bottom: o = NSPoint(x: t.midX - s.width / 2, y: t.maxY + 4)
        case .left: o = NSPoint(x: t.maxX + 4, y: t.midY - s.height / 2)
        case .right: o = NSPoint(x: t.minX - 4 - s.width, y: t.midY - s.height / 2)
        }
        panel.setFrameOrigin(NSPoint(x: clamp(o.x, 4, b.width - s.width - 4), y: clamp(o.y, 4, b.height - s.height - 4)))
        content.addSubview(panel)
        owner.window.invalidateCursorRects(for: panel)
    }

    @objc func pickSharp(_ sender: NSSegmentedControl) {
        hide()
        viewer.setSharp(sender.selectedSegment == 1)
    }

    func hide() {
        cancelDwell()
        watch?.invalidate()
        watch = nil
        awaySince = nil
        panel.removeFromSuperview()
        guard tab.superview != nil else { return }
        let out = outside(tab.frame)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.15
            tab.animator().frame = out
        }, completionHandler: { [weak self] in
            // Unless it came out again meanwhile.
            if let self, !self.isShown { self.tab.removeFromSuperview() }
        })
    }
}

/// One machine's window. It is the window's delegate, so the View menu's items reach it.
final class MachineWindow: NSObject, NSWindowDelegate, NSMenuItemValidation, WKNavigationDelegate,
                           WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private(set) var machine: Machine
    /// The screen on view: its place in machine.screens.
    private(set) var row = 0
    let window: NSWindow
    let config = WKWebViewConfiguration()
    /// The web view, and over it the chip, the edge tab and its panel.
    let content = NSView()
    var web: ViewerWebView!
    let chip = Chip()
    lazy var switcher = Switcher(owner: self)
    /// The tab row under the title bar: a tab per screen, the one on view selected, and Full | Sharp
    /// when the machine has Sharp streams. Only on a machine with more than one screen; in full
    /// screen it goes with the title bar (the edge tab is there).
    let tabsBar = NSTitlebarAccessoryViewController()
    let screenTabs = NSSegmentedControl()
    let sharpTabs = NSSegmentedControl(labels: ["Full", "Sharp"], trackingMode: .selectOne, target: nil, action: nil)
    var settings: SettingsWindow?
    let onClose: (MachineWindow) -> Void
    var stats = false
    /// The page last asked for, and whether the screen has answered and shown it.
    var loaded: URL?
    var answered = false, committed = false
    /// From each load until voxl's page connects (or 3 s): keys typed meanwhile were meant for the
    /// screen before, so they stay here.
    var connecting = false
    /// The screen on view doesn't answer: its note stays up while it's tried again every 3 s.
    var failing = false
    /// What the chip says while nothing flashes on it (nil: it's away).
    var chipText: String?
    var retryLater, waitLater, flashLater: DispatchWorkItem?
    /// The F key of the last switch, whose release stays here too.
    var eaten: UInt16?
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
        for source in [bridge, pictureWatch] {
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController.add(self, name: "clip")
        config.userContentController.add(self, name: "viewer")

        // Black, as voxl's page is, while a screen connects.
        window.backgroundColor = .black
        content.clipsToBounds = true
        window.contentView = content
        // Mouse moves over the picture, for the edge tab.
        content.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                               owner: content, userInfo: nil))
        newWebView()
        content.addSubview(chip)
        makeTabs()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("voxl " + machine.id)
        window.makeKeyAndOrderFront(nil)
        load()
    }

    var screen: Screen { machine.screens[row] }
    var label: String { "\(row + 1) · \(screen.name)" }
    var sharp: Bool { sharpChosen && machine.hasSharp }

    /// The page for the screen on view: its Sharp or Full URL, with voxl's stats overlay if it's on.
    var pageURL: URL {
        var url = sharp ? screen.sharp ?? screen.url : screen.url
        if stats, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Keep any ?token= as it was typed.
            c.percentEncodedQueryItems = (c.percentEncodedQueryItems ?? []) + [URLQueryItem(name: "stats", value: nil)]
            url = c.url ?? url
        }
        return url
    }

    func newWebView() {
        if let old = web {
            old.mutePage(true)
            old.navigationDelegate = nil
            old.uiDelegate = nil
            old.stopLoading()
            old.removeFromSuperview()
        }
        web = ViewerWebView(frame: content.bounds, configuration: config)
        web.mutePage(true)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.uiDelegate = self
        // Clear, not white, until voxl's page draws its own black.
        if web.responds(to: NSSelectorFromString("_setDrawsBackground:")) { web.setValue(false, forKey: "drawsBackground") }
        web.underPageBackgroundColor = .black
        content.addSubview(web, positioned: .below, relativeTo: nil)
        window.makeFirstResponder(web)
    }

    /// Sound follows the window in front, after real input here and the host's launch grace.
    func updateAudio() {
        let audible = committed && window.isKeyWindow && NSApp.isActive && !window.isMiniaturized
            && viewer.canPlayAudio
        web.mutePage(!audible)
    }

    /// Connects to the screen on view. A web view that has shown a page is swapped for a new one:
    /// WebKit would keep that page, and its stream, running in its back-forward cache.
    func load() {
        retryLater?.cancel()
        retryLater = nil
        if committed { newWebView() }
        let url = pageURL
        loaded = url
        answered = false
        committed = false
        connecting = true
        if !failing { setChip(label) }
        updateTitle()
        waitThenCheck()
        web.load(URLRequest(url: url))
    }

    /// In 3 s: waited().
    func waitThenCheck() {
        waitLater?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.waited() }
        waitLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// 3 s after a try (or a late answer): the chip goes if the screen answered. If it hasn't, the
    /// chip says so while the try goes on, so a slow screen still connects; one with still no answer
    /// 10 s into the try gets a new one. A password prompt is an answer, so it's never cut off. A try
    /// that fails is tried again 3 s later (retry()).
    func waited() {
        connecting = false
        if answered {
            if !failing { setChip(nil) }
            return
        }
        notAnswering()
        guard retryLater == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.answered else { return }
            self.load()
        }
        retryLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    func notAnswering() {
        failing = true
        var text = "\(screen.name) isn't answering. Trying again every 3 s."
        if machine.screens.count > 1 {
            let other = row == 0 ? 1 : 0
            text += " \(shortcut(other)): \(machine.screens[other].name)"
        }
        setChip(text)
    }

    /// Another screen, or the same one connected again; the window's size, place and full screen stay.
    func reconnect() {
        failing = false
        window.subtitle = ""
        load()
    }

    /// F1..F9 or a tab: screen N, or its name again if it's the one on view.
    func go(to n: Int) {
        switcher.hide()
        guard n < machine.screens.count else { return flash("\(machine.name) has no screen \(n + 1)") }
        if n == row { return flash(label) }
        row = n
        reconnect()
    }

    /// A row of the panel: another screen, or the one on view connected again (for a stuck picture).
    func choose(_ n: Int) {
        guard n < machine.screens.count else { return }
        row = n
        reconnect()
    }

    /// A change from Settings, saved at once. The screen on view connects again only if its address
    /// changed, or if it was removed (then the first one opens).
    func apply(_ m: Machine, viewing r: Int?) {
        Machine.keep(m)
        show(m, viewing: r)
    }

    /// The machine as it now is, on screen r (nil: the one on view is gone, so the first).
    func show(_ m: Machine, viewing r: Int?) {
        machine = m
        row = min(r ?? 0, m.screens.count - 1)
        switcher.hide()
        if r == nil || pageURL != loaded { reconnect() } else { updateTitle() }
    }

    /// Catches up with the saved settings, which another copy of the app (each launcher is one) or a
    /// seed may have changed: this machine's screens, and Full | Sharp. Edits then start from them.
    func reread() {
        guard let saved = Machine.saved.first(where: { $0.id == machine.id }), saved != machine else {
            return sharpChanged()
        }
        show(saved, viewing: saved.screens.firstIndex { $0.url == screen.url })
        settings?.fill()
    }

    /// Full or Sharp changed, for every machine.
    func sharpChanged() {
        guard let loaded, pageURL != loaded else { return updateTitle() }
        switcher.hide()
        reconnect()
    }

    /// "M3 · top · Sharp": the machine, the screen (left out when it's the only one and named the
    /// same) and Full or Sharp when the machine has the choice.
    func updateTitle() {
        var parts = [machine.name]
        if machine.screens.count > 1 || screen.name != machine.name { parts.append(screen.name) }
        if machine.hasSharp { parts.append(sharp ? "Sharp" : "Full") }
        window.title = parts.joined(separator: " · ")
        settings?.retitle()
        updateTabs()
    }

    func makeTabs() {
        screenTabs.trackingMode = .selectOne
        screenTabs.target = self
        screenTabs.action = #selector(pickScreen(_:))
        sharpTabs.target = self
        sharpTabs.action = #selector(pickSharp(_:))
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        for c in [screenTabs, sharpTabs] {
            c.refusesFirstResponder = true // keys keep going to the remote
            c.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(c)
        }
        NSLayoutConstraint.activate([
            screenTabs.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            screenTabs.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            sharpTabs.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            sharpTabs.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        tabsBar.view = bar
        tabsBar.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(tabsBar)
        updateTabs()
    }

    func updateTabs() {
        tabsBar.isHidden = machine.screens.count < 2
        guard !tabsBar.isHidden else { return }
        screenTabs.segmentCount = machine.screens.count
        for (i, s) in machine.screens.enumerated() {
            screenTabs.setLabel("\(i + 1) · \(s.name)    \(shortcut(i))", forSegment: i)
        }
        screenTabs.selectedSegment = row
        sharpTabs.isHidden = !machine.hasSharp
        sharpTabs.selectedSegment = sharp ? 1 : 0
    }

    /// The tab row is up: the edge tab stays away (it is for full screen).
    var tabsShown: Bool { !tabsBar.isHidden && !window.styleMask.contains(.fullScreen) }

    @objc func pickScreen(_ sender: NSSegmentedControl) {
        go(to: sender.selectedSegment)
        updateTabs()
        window.makeFirstResponder(web)
    }

    @objc func pickSharp(_ sender: NSSegmentedControl) {
        viewer.setSharp(sender.selectedSegment == 1)
        window.makeFirstResponder(web)
    }

    /// The chip's lasting text (nil: none). A flash shows over it for a moment.
    func setChip(_ text: String?) {
        flashLater?.cancel()
        chipText = text
        chip.show(text)
    }

    func flash(_ text: String) {
        flashLater?.cancel()
        chip.show(text)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.chip.show(self.chipText)
        }
        flashLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Each key event of this window before the page gets it (nil: it stops here).
    func key(_ e: NSEvent) -> NSEvent? {
        if typedByVoxl(e) { return nil }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        // F1..F9 with nothing else held, on a machine with more than one screen and for one it has;
        // otherwise the key goes on to the remote.
        if e.type == .keyDown, mods.isEmpty, let n = fKeys[e.keyCode], machine.screens.count > 1,
           n < machine.screens.count {
            eaten = e.keyCode
            if !e.isARepeat { go(to: n) }
            return nil
        }
        if e.keyCode == eaten {
            eaten = nil
            // The switch's release stays here; a press of that key that isn't a switch goes on.
            if e.type == .keyUp { return nil }
        }
        // While a screen connects, keys typed for the one before stay here; Cmd+Q and Ctrl+Cmd+F still work.
        guard connecting else { return e }
        if e.type == .keyDown, let k = e.charactersIgnoringModifiers?.lowercased(),
           (mods == [.command] && k == "q") || (mods == [.command, .control] && k == "f") { return e }
        return nil
    }

    // The screen is offline or voxl restarts: try it again in 3 s, never another screen instead
    // (voxl's page reconnects on its own once it has loaded).
    func retry(_ why: String) {
        window.subtitle = why
        notAnswering()
        retryLater?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load() }
        retryLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
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

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        guard w === web else { return }
        answered = true
        committed = true
        updateAudio()
        window.subtitle = ""
        if failing {
            failing = false
            setChip(label)
            // Back after being away: the chip goes with the picture, or in 3 s.
            waitThenCheck()
        }
    }

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
        if r.isForMainFrame { answered = true }
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
        answered = true
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
        alert.messageText = "Sign in to \(window.title)"
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
        // Only the page on view counts, and only from its voxl's own origin.
        guard m.webView === web, let url = loaded, isOrigin(m.frameInfo.securityOrigin, of: url) else { return }
        if m.name == "viewer" {
            connecting = false
            if m.body as? String == "picture" {
                waitLater?.cancel()
                if !failing { setChip(nil) }
            }
            return
        }
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
        updateAudio()
        resignedKey = Date()
        ownChange = NSPasteboard.general.changeCount
        // The digit's release may go to another window now.
        eaten = nil
        switcher.hide()
    }

    func windowDidBecomeKey(_ note: Notification) {
        reread()
        updateAudio()
        if let held = heldClip, NSPasteboard.general.changeCount == ownChange { writeClipboard(held) }
        heldClip = nil
    }

    func windowDidResize(_ note: Notification) { switcher.hide() }
    func windowDidMiniaturize(_ note: Notification) { updateAudio() }
    func windowDidDeminiaturize(_ note: Notification) { updateAudio() }

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
        web.mutePage(true)
        retryLater?.cancel()
        waitLater?.cancel()
        flashLater?.cancel()
        switcher.hide()
        settings?.window.close()
        config.userContentController.removeScriptMessageHandler(forName: "clip")
        config.userContentController.removeScriptMessageHandler(forName: "viewer")
        onClose(self)
    }

    @objc func reloadMachine(_ sender: Any?) { reconnect() }
    @objc func toggleVoxlStats(_ sender: Any?) { stats.toggle(); reconnect() }

    @objc func openSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindow(owner: self) }
        settings?.window.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleVoxlStats(_:)) { item.state = stats ? .on : .off }
        return true
    }
}

/// A machine's settings: its name and its screens in order, and the tab's edge (for every machine).
/// Each change is saved at once; the picture connects again only if the screen on view changed
/// its address.
final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    unowned let owner: MachineWindow
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let stack = NSStackView()
    let nameField = NSTextField()
    let grid = NSGridView(numberOfColumns: 7, rows: 0)
    let addButton = NSButton(title: "Add Screen…", target: nil, action: nil)
    let note = NSTextField(wrappingLabelWithString: "")
    let removeButton = NSButton(title: "Remove Machine…", target: nil, action: nil)
    var edgeButtons: [NSButton] = []
    /// Each screen's name, URL and Sharp URL fields, by row.
    var fields: [[NSTextField]] = []

    var machine: Machine { owner.machine }

    init(owner: MachineWindow) {
        self.owner = owner
        super.init()
        window.isReleasedWhenClosed = false
        // Over the viewer in full screen too, instead of macOS going to the desktop to show it.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        nameField.stringValue = owner.machine.name
        nameField.delegate = self
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        addButton.target = self
        addButton.action = #selector(addScreen(_:))
        removeButton.target = self
        removeButton.action = #selector(removeMachine(_:))
        removeButton.isHidden = !owner.machine.isSaved
        note.textColor = .systemRed
        note.preferredMaxLayoutWidth = 560
        note.isHidden = true
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        fillGrid()
        for (i, edge) in Edge.allCases.enumerated() {
            let b = NSButton(radioButtonWithTitle: edge.title, target: self, action: #selector(pickEdge(_:)))
            b.tag = i
            edgeButtons.append(b)
        }
        showEdge()
        let edges = NSGridView(views: zip(edgeButtons, Edge.allCases).map { [$0, small($1.note)] })
        edges.rowSpacing = 6
        edges.columnSpacing = 12
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let shortcuts = small("1 opens with the window. F1, F2 … go to 1, 2 …")
        for v in [NSStackView(views: [NSTextField(labelWithString: "Machine name:"), nameField]), line(), bold("Screens"),
                  grid, addButton, shortcuts, note, line(), bold("Tab edge, for every machine"), edges, line(),
                  removeButton] {
            stack.addArrangedSubview(v)
            if v is NSBox { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        }
        window.contentView = stack
        window.autorecalculatesKeyViewLoop = true
        retitle()
        window.setContentSize(stack.fittingSize)
        window.center()
    }

    func line() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func bold(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return f
    }

    func small(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        return f
    }

    func retitle() { window.title = "\(machine.name) Settings" }

    func showEdge() {
        let chosen = Edge.allCases.firstIndex(of: Edge.chosen)
        for b in edgeButtons { b.state = b.tag == chosen ? .on : .off }
    }

    /// One row per screen: "1 Default", "2 Secondary", then numbers.
    func fillGrid() {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        let count = machine.screens.count
        let empty = NSGridCell.emptyContentView
        grid.addRow(with: [empty, small("Name"), small("voxl URL"), small("Sharp URL (optional)"), empty, empty, empty])
        fields = machine.screens.enumerated().map { i, s in
            let row = [field(s.name, 130, "Name"), field(s.url.absoluteString, 250, "https://my-mac.example.ts.net:6901/"),
                       field(s.sharp?.absoluteString ?? "", 250, "A smaller stream of the same screen")]
            let title = i == 0 ? "1 Default" : i == 1 ? "2 Secondary" : "\(i + 1)"
            grid.addRow(with: [NSTextField(labelWithString: title)] + row + [
                icon("chevron.up", "Move Up", #selector(moveUp(_:)), i, i > 0),
                icon("chevron.down", "Move Down", #selector(moveDown(_:)), i, i < count - 1),
                icon("minus.circle", "Remove", #selector(removeScreen(_:)), i, count > 1),
            ])
            return row
        }
        addButton.isEnabled = count < Machine.maxScreens
    }

    func field(_ text: String, _ width: CGFloat, _ hint: String) -> NSTextField {
        let f = NSTextField(string: text)
        f.placeholderString = hint
        f.delegate = self
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    func icon(_ symbol: String, _ title: String, _ action: Selector, _ row: Int, _ enabled: Bool) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                         target: self, action: action)
        b.isBordered = false
        b.toolTip = title
        b.tag = row
        b.isEnabled = enabled
        return b
    }

    /// The machine as saved, after a change from another copy of the app or a seed.
    func fill() {
        nameField.stringValue = machine.name
        fillGrid()
        say(nil)
        fit()
    }

    /// Names that arrived from voxl's page, into fields nobody is typing in.
    func refresh() {
        for (row, s) in zip(fields, machine.screens) where row[0].currentEditor() == nil {
            row[0].stringValue = s.name
        }
    }

    /// Keeps the window's top left where it is.
    func fit() {
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: stack.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    func say(_ text: String?) {
        guard note.stringValue != text ?? "" else { return }
        note.stringValue = text ?? ""
        note.isHidden = text == nil
        fit()
    }

    /// Saves a change at once. A machine opened from a link alone joins the Machines menu with it.
    func save(_ m: Machine, viewing r: Int?) {
        owner.apply(m, viewing: r)
        if removeButton.isHidden {
            removeButton.isHidden = false
            fit()
        }
    }

    /// A field was left (Return, Tab or a click elsewhere): saved, if it's usable.
    func controlTextDidEndEditing(_ n: Notification) {
        guard let f = n.object as? NSTextField else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespaces)
        var m = machine
        if f === nameField {
            if !text.isEmpty { m.name = text }
            f.stringValue = m.name
        } else if let i = fields.firstIndex(where: { $0.contains(f) }), let part = fields[i].firstIndex(of: f),
                  i < m.screens.count {
            switch part {
            case 0:
                m.screens[i].name = text.isEmpty ? hostPort(m.screens[i].url) : text
                f.stringValue = m.screens[i].name
            case 1:
                guard let url = voxlURL(text) else {
                    return say("Screen \(i + 1) isn't saved: enter its whole address, starting with https:// or http://.")
                }
                if let used = screenUsing(url, besides: (m.id, i), also: m) {
                    return say("Screen \(i + 1) isn't saved: that address is already screen \(used.row + 1) of \(used.machine.name).")
                }
                m.screens[i].url = url
                f.stringValue = url.absoluteString
            default:
                if text.isEmpty {
                    m.screens[i].sharp = nil
                } else if let url = voxlURL(text) {
                    m.screens[i].sharp = url
                    f.stringValue = url.absoluteString
                } else {
                    return say("Screen \(i + 1)'s Sharp URL isn't saved: enter its whole address, starting with https:// or http://.")
                }
            }
        } else {
            return
        }
        say(nil)
        if m != machine { save(m, viewing: owner.row) }
    }

    /// A pasted voxl link; its name comes from voxl's page when it answers.
    @objc func addScreen(_ sender: Any?) {
        window.makeFirstResponder(nil)
        guard machine.screens.count < Machine.maxScreens else { return }
        var note = "Paste the voxl link of another screen of \(machine.name)."
        var text = ""
        while true {
            let alert = NSAlert()
            alert.messageText = "Add a screen"
            alert.informativeText = note
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
            field.stringValue = text
            field.placeholderString = "https://my-mac.example.ts.net:6902/"
            alert.accessoryView = field
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let url = voxlURL(text) else {
                note = "Enter the whole address, starting with https:// or http://."
                continue
            }
            if let used = screenUsing(url, also: machine) {
                note = "That address is already screen \(used.row + 1) of \(used.machine.name)."
                continue
            }
            var m = machine
            m.screens.append(Screen(name: hostPort(url), url: url))
            save(m, viewing: owner.row)
            fillGrid()
            fit()
            fetchTitle(url) { title in viewer.named(url, title) }
            return
        }
    }

    @objc func moveUp(_ sender: NSButton) { move(sender.tag, to: sender.tag - 1) }
    @objc func moveDown(_ sender: NSButton) { move(sender.tag, to: sender.tag + 1) }

    /// Swaps two screens; the one on view stays on view, under its new number.
    func move(_ i: Int, to j: Int) {
        window.makeFirstResponder(nil)
        guard machine.screens.indices.contains(i), machine.screens.indices.contains(j) else { return }
        var m = machine
        m.screens.swapAt(i, j)
        let r = owner.row
        save(m, viewing: r == i ? j : r == j ? i : r)
        fillGrid()
    }

    @objc func removeScreen(_ sender: NSButton) {
        let i = sender.tag
        window.makeFirstResponder(nil)
        guard machine.screens.count > 1, machine.screens.indices.contains(i) else { return }
        var m = machine
        m.screens.remove(at: i)
        let r = owner.row
        save(m, viewing: r == i ? nil : r > i ? r - 1 : r)
        fillGrid()
        fit()
    }

    @objc func pickEdge(_ sender: NSButton) {
        defaults.set(Edge.allCases[sender.tag].rawValue, forKey: "edge")
        showEdge()
        viewer.edgeChanged()
    }

    @objc func removeMachine(_ sender: Any?) {
        window.makeFirstResponder(nil)
        let alert = NSAlert()
        alert.messageText = "Remove \(machine.name)?"
        alert.informativeText = "It leaves the Machines menu, with its screens. Its window stays open until you close it."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            let id = self.machine.id
            Machine.forget(id)
            if defaults.string(forKey: "lastMachine") == id { defaults.removeObject(forKey: "lastMachine") }
            self.window.close()
        }
    }

    func windowDidBecomeKey(_ note: Notification) {
        showEdge()
        owner.reread()
    }

    /// The field being typed in is saved when the window goes to the back (and as the app quits).
    func windowDidResignKey(_ note: Notification) { window.makeFirstResponder(nil) }

    /// The field being typed in is saved as the window closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.makeFirstResponder(nil)
        return true
    }

    func windowWillClose(_ note: Notification) { owner.settings = nil }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var windows: [MachineWindow] = []
    var selfTestFailed = false
    let launched = Date()
    var lastInput = Date.distantPast
    var screenLocked = false, screensAsleep = false
    var audioTimer: Timer?

    /// Date includes time spent asleep, so waking after five minutes needs real input again.
    var canPlayAudio: Bool {
        let now = Date()
        return !screenLocked && !screensAsleep && now.timeIntervalSince(launched) >= 2
            && now.timeIntervalSince(lastInput) < 5 * 60
    }

    func updateAudio() { windows.forEach { $0.updateAudio() } }

    /// Input a voxl host posted (someone controlling this Mac from elsewhere) isn't someone here.
    func physicalInput(_ e: NSEvent) {
        guard !typedByVoxl(e) else { return }
        let back = Date().timeIntervalSince(lastInput) >= 5 * 60
        lastInput = Date()
        // Mouse moves come many times a second; the 250 ms timer covers the rest.
        if back { updateAudio() }
    }

    func watchAudio() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(self, selector: #selector(screenStateChanged(_:)),
                                    name: Notification.Name(name), object: nil, suspensionBehavior: .deliverImmediately)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(self, selector: #selector(screenStateChanged(_:)), name: name, object: nil)
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateAudio() }
        RunLoop.main.add(timer, forMode: .common)
        audioTimer = timer
    }

    @objc func screenStateChanged(_ note: Notification) {
        switch note.name {
        case Notification.Name("com.apple.screenIsLocked"): screenLocked = true
        case Notification.Name("com.apple.screenIsUnlocked"): screenLocked = false
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        default: return
        }
        updateAudio()
    }

    func applicationDidBecomeActive(_ note: Notification) { updateAudio() }
    func applicationDidResignActive(_ note: Notification) { updateAudio() }

    /// The machine in front (its window, or its Settings).
    var current: MachineWindow? {
        windows.first { $0.window.isMainWindow || $0.settings?.window.isMainWindow == true }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        watchInput()
        watchAudio()
        // Other copies of the app (each launcher is one) and seeds change these too.
        for key in ["machineList", "sharp"] { defaults.addObserver(self, forKeyPath: key, options: [], context: nil) }
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

    /// A field half typed in Settings is saved on Cmd+Q too.
    func applicationWillTerminate(_ note: Notification) {
        audioTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        windows.forEach { $0.settings?.window.makeFirstResponder(nil) }
    }

    /// The machines or Full | Sharp changed, in this copy of the app or another: each window catches up.
    override func observeValue(forKeyPath key: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { self.windows.forEach { $0.reread() } }
    }

    /// Keys and mouse go through the window in front first: its shortcuts, and its edge tab.
    func watchInput() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            self?.physicalInput(e)
            guard let w = self?.windows.first(where: { $0.window.isKeyWindow }) else { return e }
            return w.key(e)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                    .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged,
                                                    .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] e in
            self?.physicalInput(e)
            self?.windows.first(where: { $0.window.isKeyWindow })?.switcher.mouse(e)
            return e
        }
        // The mouse in other apps counts too: someone using this Mac a minute ago in another app
        // is here when they bring a viewer forward. (Watching other apps' keys needs a privacy grant.)
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                     .leftMouseDragged, .scrollWheel]) { [weak self] e in
            self?.physicalInput(e)
        }
    }

    /// A URL argument (and an optional name after it), else this bundle's VoxlURL: the saved machine
    /// with a screen there, else that URL as a machine of its own.
    func launchMachine() -> Machine? {
        let args = Array(CommandLine.arguments.dropFirst())
        var url: URL?, name = appName
        if let i = args.firstIndex(where: { voxlURL($0) != nil }), let u = voxlURL(args[i]) {
            url = u
            name = args.indices.contains(i + 1) && !args[i + 1].hasPrefix("-") ? args[i + 1] : u.host!
        } else {
            url = (Bundle.main.infoDictionary?["VoxlURL"] as? String).flatMap(voxlURL)
        }
        guard let url else { return nil }
        // The machine with that screen now, before one whose first screen it once was.
        let saved = Machine.saved
        return saved.first { $0.has(url) } ?? saved.first { $0.owns(url) } ?? Machine(url: url, name: name)
    }

    func lastMachine() -> Machine? {
        let saved = Machine.saved
        if let m = saved.first(where: { $0.id == defaults.string(forKey: "lastMachine") }) { return m }
        // Older versions kept the last machine's URL.
        if let url = defaults.string(forKey: "lastURL").flatMap(voxlURL), let m = saved.first(where: { $0.owns(url) }) {
            return m
        }
        return saved.first
    }

    /// The machine's window, at its first screen, or its window to the front if it's open.
    func open(_ m: Machine) {
        if let w = windows.first(where: { $0.machine.id == m.id }) {
            return w.window.makeKeyAndOrderFront(nil)
        }
        windows.append(MachineWindow(machine: m) { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        })
        if m.isSaved { defaults.set(m.id, forKey: "lastMachine") }
    }

    @objc func openMachine(_ item: NSMenuItem) {
        if let m = Machine.saved.first(where: { $0.id == item.representedObject as? String }) { open(m) }
    }

    /// A new machine with its first screen; Settings… adds the others.
    @objc func addMachine(_ sender: Any?) {
        guard let m = machineDialog() else { return }
        Machine.keep(m)
        open(m)
        let url = m.screens[0].url
        fetchTitle(url) { [weak self] title in self?.named(url, title) }
    }

    /// Name and the voxl link of one of its screens. Asks again until the link is a usable one.
    func machineDialog() -> Machine? {
        var note = "A name for the Machines menu, and the voxl link of one of the machine's screens. Settings… adds more."
        var name = "", url = ""
        while true {
            let alert = NSAlert()
            alert.messageText = "Add a machine"
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
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = nameField
            let r = alert.runModal()
            name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            guard r == .alertFirstButtonReturn else { return nil }
            guard let u = voxlURL(url) else {
                note = "Enter the whole address, starting with https:// or http://."
                continue
            }
            if let used = screenUsing(u) {
                note = "That address is already screen \(used.row + 1) of \"\(used.machine.name)\"."
                continue
            }
            return Machine(id: UUID().uuidString, name: name.isEmpty ? u.host! : name,
                           screens: [Screen(name: hostPort(u), url: u)])
        }
    }

    /// Full | Sharp, for every machine: each window whose page changes connects again.
    func setSharp(_ on: Bool) {
        defaults.set(on, forKey: "sharp")
        windows.forEach { $0.sharpChanged() }
    }

    func edgeChanged() { windows.forEach { $0.switcher.hide() } }

    /// voxl's page title for a screen just added under its host:port: that becomes its name, unless
    /// it was renamed meanwhile.
    func named(_ url: URL, _ title: String) {
        let w = windows.first { $0.machine.screens.contains { $0.url == url } }
        w?.reread()
        guard var m = w?.machine ?? Machine.saved.first(where: { $0.screens.contains { $0.url == url } }),
              let i = m.screens.firstIndex(where: { $0.url == url }), m.screens[i].name == hostPort(url) else { return }
        m.screens[i].name = title
        if let w {
            w.apply(m, viewing: w.row)
            w.settings?.refresh()
        } else {
            Machine.keep(m)
        }
    }

    // The Machines menu is rebuilt each time it opens, so every app copy shows the current list.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for m in Machine.saved {
            let item = NSMenuItem(title: m.name, action: #selector(openMachine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.id
            item.state = current?.machine.id == m.id ? .on : .off
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "Add Machine…", action: #selector(addMachine(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        // The window in front's (its delegate, through the responder chain).
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(MachineWindow.openSettings(_:)), keyEquivalent: ""))
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
        _ = menu(appName, [item("Settings…", #selector(MachineWindow.openSettings(_:))), .separator(),
                           item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")])
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
