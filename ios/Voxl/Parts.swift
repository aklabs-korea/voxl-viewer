import UIKit

// Part of a screen, as in the desktop viewers: the screen's tab (or its F key) again steps Whole,
// Left half, Right half, the window under the Mac's pointer, Whole. Each screen keeps its part. The
// stream doesn't change: the picture's box takes the part's shape and the page zooms into it
// (Pointer's area), and the trackpad cursor stops at the part's edges.
//
// A window part asks the screen's voxl where the window is twice a second (voxl's window routes): the
// view follows it, goes to the machine's other screen with it, and back to Whole when it's closed or
// minimized. With Fit window on, voxl gives that window the shape of the picture's room here, and puts
// it back when the part changes or the app goes to the background, unless it was moved or resized at
// the Mac since.

/// What the picture shows of its screen.
enum Part: Equatable {
    case whole, left, right
    /// One of the Mac's windows; box is where it is, as fractions of the screen.
    case window(id: UInt64, app: String, box: CGRect)

    var box: CGRect {
        switch self {
        case .whole: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .left: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .window(_, _, let box): return box
        }
    }

    var windowID: UInt64? { if case .window(let id, _, _) = self { return id } else { return nil } }

    var name: String {
        switch self {
        case .whole: return "Whole"
        case .left: return "Left half"
        case .right: return "Right half"
        case .window(_, let app, _): return app.isEmpty ? "Window" : app
        }
    }
}

/// While the picture shows one of the Mac's windows, voxl can give that window the shape of the
/// picture's room here: Large is one Mac pixel per point here, Fine one per pixel, Medium in between.
enum FitSize: String, CaseIterable {
    case off, large, medium, fine

    static var chosen: FitSize {
        get { FitSize(rawValue: UserDefaults.standard.string(forKey: "fit") ?? "") ?? .large }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "fit") }
    }

    /// Mac pixels per point here, on a screen with k pixels per point.
    func factor(_ k: CGFloat) -> CGFloat {
        switch self {
        case .off, .large: return 1
        case .medium: return k.squareRoot()
        case .fine: return k
        }
    }
}

/// Where voxl says the window is, as fractions of the screen, cut to the screen.
func windowBox(_ j: [String: Any]) -> CGRect? {
    guard let x = (j["x"] as? NSNumber)?.doubleValue, let y = (j["y"] as? NSNumber)?.doubleValue,
          let w = (j["w"] as? NSNumber)?.doubleValue, let h = (j["h"] as? NSNumber)?.doubleValue,
          let screen = j["screen"] as? [String: Any], let sw = (screen["w"] as? NSNumber)?.doubleValue,
          let sh = (screen["h"] as? NSNumber)?.doubleValue, sw > 0, sh > 0 else { return nil }
    let r = CGRect(x: x / sw, y: y / sh, width: w / sw, height: h / sh).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    return r.isNull || r.isEmpty ? nil : r
}

/// voxl's window routes on a screen's voxl (its Full URL: Sharp shows the same display), with the
/// password this run signed in with. The answer comes on the main queue.
func windowCall(_ screen: Screen, _ path: String, post body: [String: Any]? = nil,
                _ done: @escaping (Int, [String: Any]) -> Void = { _, _ in }) {
    guard var c = URLComponents(url: screen.url, resolvingAgainstBaseURL: false) else { return }
    let token = c.queryItems?.first { $0.name == "token" }?.value
    c.path = path
    c.query = nil
    c.fragment = nil
    guard let url = c.url else { return }
    var r = URLRequest(url: url, timeoutInterval: 3)
    r.setValue("1", forHTTPHeaderField: "X-Voxl-Window")
    let scheme = c.scheme ?? ""
    if let token {
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    } else if let login = Password.signedIn["\(scheme)://\(c.host ?? ""):\(c.port ?? (scheme == "https" ? 443 : 80))"],
              let user = login.user, let password = login.password {
        r.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    }
    if let body {
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    URLSession.shared.dataTask(with: r) { data, response, _ in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        DispatchQueue.main.async { done(status, json) }
    }.resume()
}

/// The part's state while the app runs.
final class PartState {
    /// Each screen's part, by its URL.
    var parts: [String: Part] = [:]
    var follow: Timer?
    /// Bumped by every change of screen or part: answers to earlier questions are dropped.
    var turn = 0
    var asking = false
    var fitAsked = Date.distantPast
    let note = UILabel()
}

extension ViewerController {
    var part: Part { screen.flatMap { parts.parts[$0.url.absoluteString] } ?? .whole }

    /// The screen's tab or F key again: Whole, Left, Right, the window under the Mac's pointer, Whole.
    func step() {
        switch part {
        case .whole: setPart(.left)
        case .left: setPart(.right)
        case .right: pickWindow()
        case .window: setPart(.whole)
        }
    }

    /// Shows part p of the screen on view, and says so (or note).
    func setPart(_ p: Part, note: String? = nil) {
        guard let screen else { return }
        if let id = part.windowID, id != p.windowID { leaveWindow() }
        parts.parts[screen.url.absoluteString] = p
        TestLog.shared.add("part", ["screen": label, "part": p.name])
        pointer.show(box: p.box)
        updateNav()
        say(note ?? "\(row + 1) · \(screen.name) · \(p.name)")
        watchWindow()
    }

    /// A short note over the picture.
    func say(_ text: String) {
        let n = parts.note
        if n.superview == nil {
            n.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
            n.textColor = .white
            n.font = .systemFont(ofSize: 15, weight: .medium)
            n.textAlignment = .center
            n.numberOfLines = 0
            n.layer.cornerRadius = 10
            n.clipsToBounds = true
            n.isUserInteractionEnabled = false
            view.addSubview(n)
        }
        n.text = text
        let size = n.sizeThatFits(CGSize(width: min(320, pictureBox.bounds.width - 32), height: 200))
        n.frame = CGRect(x: pictureBox.frame.midX - size.width / 2 - 14, y: pictureBox.frame.midY - size.height / 2 - 8,
                         width: size.width + 28, height: size.height + 16)
        n.alpha = 1
        UIView.animate(withDuration: 0.4, delay: 2.5, options: []) { n.alpha = 0 }
    }

    /// The window under the Mac's pointer becomes the part; with none, the whole screen.
    func pickWindow() {
        guard let screen else { return }
        let turn = parts.turn
        windowCall(screen, "/window/at-pointer") { [weak self] status, j in
            guard let self, turn == self.parts.turn else { return }
            let app = j["app"] as? String ?? ""
            guard status == 200, let id = (j["id"] as? NSNumber)?.uint64Value else {
                return self.setPart(.whole, note: status == 204 ? "No window under the pointer: whole screen"
                                    : "\(screen.name) can't show one window: whole screen")
            }
            if j["elsewhere"] as? Bool == true { return self.findWindow(id, app: app) }
            guard let box = windowBox(j) else { return self.setPart(.whole) }
            self.setPart(.window(id: id, app: app, box: box))
        }
    }

    /// While the part is a window and the app is in front: fits it, and asks where it is twice a second.
    func watchWindow() {
        parts.turn += 1
        parts.follow?.invalidate()
        parts.follow = nil
        guard part.windowID != nil, active else { return }
        fitWindow()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.askWhere() }
        RunLoop.main.add(timer, forMode: .common)
        parts.follow = timer
    }

    /// The view follows the window. Moved to another of the machine's screens, that screen comes on view
    /// with it; closed or minimized, the whole screen.
    func askWhere() {
        guard !parts.asking, let screen, case .window(let id, let app, let box) = part else { return }
        let turn = parts.turn
        parts.asking = true
        windowCall(screen, "/window/\(id)") { [weak self] status, j in
            self?.parts.asking = false
            guard let self, turn == self.parts.turn else { return }
            if status == 404 {
                return self.setPart(.whole, note: "\(app.isEmpty ? "The window" : app) closed or minimized: whole screen")
            }
            guard status == 200 else { return } // voxl restarting or offline: ask again
            if j["elsewhere"] as? Bool == true { return self.findWindow(id, app: app) }
            if let now = windowBox(j), now != box {
                self.parts.parts[screen.url.absoluteString] = .window(id: id, app: app, box: now)
                self.pointer.show(box: now, keepZoom: true)
            }
            // Not fitted (yet, or any more after a while unasked): fit it. Moved or resized at the Mac
            // ("changed"), it stays as it is.
            let fit = j["fit"] as? String
            if FitSize.chosen != .off, fit == nil, -self.parts.fitAsked.timeIntervalSinceNow > 5 { self.fitWindow() }
            if FitSize.chosen == .off, fit == "on" { windowCall(screen, "/window/\(id)/restore", post: [:]) }
        }
    }

    /// Has voxl give the part's window the shape of the picture's room here (the keyboard down), at the
    /// size chosen.
    func fitWindow() {
        guard FitSize.chosen != .off, let screen, case .window(let id, let app, _) = part else { return }
        parts.fitAsked = Date()
        let room = Layout.frames(size: view.bounds.size, safe: view.safeAreaInsets, fold: fold, keyboardTop: nil,
                                 aspect: pointer.aspect).room
        let f = FitSize.chosen.factor(view.window?.screen.scale ?? UIScreen.main.scale)
        let turn = parts.turn
        windowCall(screen, "/window/\(id)/fit",
                   post: ["w": (room.width * f).rounded(), "h": (room.height * f).rounded()]) { [weak self] status, j in
            guard let self, status == 200 else { return }
            guard turn == self.parts.turn else {
                // Left while voxl fitted it, so the put-back sent on leaving may have come first: again.
                if self.part.windowID != id { windowCall(screen, "/window/\(id)/restore", post: [:]) }
                return
            }
            guard let box = windowBox(j) else { return }
            self.parts.parts[screen.url.absoluteString] = .window(id: id, app: app, box: box)
            self.pointer.show(box: box)
        }
    }

    /// Fit window changed.
    func fitChanged() {
        guard let screen, let id = part.windowID else { return }
        if FitSize.chosen == .off { windowCall(screen, "/window/\(id)/restore", post: [:]) } else { fitWindow() }
    }

    /// The part's window moved to another of the machine's screens: that screen, showing it.
    func findWindow(_ id: UInt64, app: String) {
        guard let machine else { return }
        let turn = parts.turn
        let others = machine.screens.indices.filter { $0 != row }
        func next(_ i: Int) {
            guard i < others.count else {
                return setPart(.whole, note: "\(app.isEmpty ? "The window" : app) is on a screen not in this machine: whole screen")
            }
            let r = others[i], other = machine.screens[r]
            windowCall(other, "/window/\(id)") { [weak self] status, j in
                guard let self, turn == self.parts.turn else { return }
                guard status == 200, j["elsewhere"] as? Bool != true, let box = windowBox(j) else { return next(i + 1) }
                self.leaveWindow()
                if let screen = self.screen { self.parts.parts[screen.url.absoluteString] = .whole }
                self.parts.parts[other.url.absoluteString] = .window(id: id, app: app, box: box)
                self.row = r
                self.switched()
            }
        }
        next(0)
    }

    /// Stops following the part's window and has voxl put it back, unless it was moved or resized at the
    /// Mac since. The screen keeps its part for when it's on view again.
    func leaveWindow() {
        parts.follow?.invalidate()
        parts.follow = nil
        parts.turn += 1
        guard let screen, let id = part.windowID else { return }
        windowCall(screen, "/window/\(id)/restore", post: [:])
    }

    /// The More menu's Fit window choice.
    var fitMenu: UIMenu {
        UIMenu(title: "Fit the Mac's window", image: UIImage(systemName: "macwindow"), children: FitSize.allCases.map { size in
            UIAction(title: size == .off ? "Off" : size.rawValue.capitalized, state: FitSize.chosen == size ? .on : .off) {
                [weak self] _ in
                FitSize.chosen = size
                self?.fitChanged()
            }
        })
    }
}
