import UIKit
import WebKit

/// The one screen: the screen tabs, voxl's page for the screen on view, the pad and the key bar.
///
/// Connecting works as in the Mac viewer: each try gets a fresh web view, the cover stays until the
/// picture plays, a screen with no answer in 3 s says so and is tried again every 3 s, and the app
/// never switches screens by itself. On top of that, a page with no hello 10 s after it loaded or
/// lost its socket gets a fresh web view (WebKit can leave a resumed socket hanging).
final class ViewerController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
                              WKDownloadDelegate {
    var machines = Store.machines
    var machineIndex = 0
    var row = 0
    let config = WKWebViewConfiguration()
    var web: WKWebView?
    let pictureBox = UIView()
    let cover = Cover()
    let nav = UIStackView()
    let tabs = UIStackView()
    let machineButton = UIButton(configuration: .plain())
    let fitButton = UIButton(configuration: .gray())
    let filesButton = UIButton(configuration: .plain())
    let moreButton = UIButton(configuration: .plain())
    /// Over the picture: it takes every touch, so voxl's own touch handling never runs beside the app's.
    let touchLayer = UIView()
    let pad = UIView()
    let modeControl = UISegmentedControl(items: ["Trackpad", "Direct"])
    let hint = UILabel()
    let keyBar = KeyBar()
    let pointer = Pointer()
    /// Each screen's zoom and pointer while the app runs, by page URL.
    var views: [String: Pointer.State] = [:]
    var keyboardTop: CGFloat?
    var downloads: [ObjectIdentifier: URL] = [:]

    // The try on view: what was loaded, and how far it got.
    var loaded: URL?
    var answered = false, committed = false, hello = false, picture = false
    var failing = false
    /// The picture is wider than the phone plays (another viewer asked for Full).
    var tooWide = false
    /// Dan cancelled voxl's password sheet: nothing tries again until he asks.
    var needsPassword = false
    /// What the cover's button does: it follows what the cover says, never a flag left from before.
    enum CoverAction { case none, otherScreen, sharp, signIn, machines }
    var coverAction = CoverAction.none
    /// This page's socket closed once: the next open is a reconnect.
    var reconnecting = false
    var waitLater, retryLater, helloLater, tooWideLater: DispatchWorkItem?
    /// The desktop's shape, from voxl's hello; Sharp's until then.
    var aspect: CGFloat = 4096.0 / 1728.0

    // In front, the sound rule, the background.
    var active = false
    var lastInput = Date.distantPast
    var closeLater: DispatchWorkItem?
    var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var muted: Bool?
    var keyboardShown = false
    var fold: CGRect?
    var laidOut = false
    var laidOutFrames: Frames?
    var stats: [String: Any] = [:]
    var audioState = "none"
    var ticks = 0

    var machine: Machine? { machines.indices.contains(machineIndex) ? machines[machineIndex] : nil }
    var screen: Screen? { machine.flatMap { $0.screens.indices.contains(row) ? $0.screens[row] : nil } }
    var label: String { "\(machine?.name ?? "") · \(row + 1) · \(screen?.name ?? "")" }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    /// No side rail: the picture takes the whole width, as a full-screen player should.
    override var preferredVerticalBarBehavior: UIVerticalBarBehavior { .disabled }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        if TestLog.shared.on {
            config.userContentController.addUserScript(WKUserScript(source: "window.voxlTrace = true;",
                                                                    injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        for (source, time) in [(Page.watch, WKUserScriptInjectionTime.atDocumentStart), (Page.input, .atDocumentStart),
                               (Page.clipboard, .atDocumentStart), (Page.style, .atDocumentEnd)] {
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: time, forMainFrameOnly: true))
        }
        config.userContentController.add(self, name: "viewer")
        config.userContentController.add(self, name: "clip")

        pictureBox.backgroundColor = .black
        pictureBox.clipsToBounds = true
        view.addSubview(pictureBox)
        pictureBox.addSubview(touchLayer)
        touchLayer.accessibilityIdentifier = "picture"
        cover.accessibilityIdentifier = "cover"
        cover.onButton = { [weak self] in self?.coverButton() }
        view.addSubview(cover)

        machineButton.showsMenuAsPrimaryAction = true
        fitButton.configuration?.buttonSize = .small
        fitButton.accessibilityLabel = "Zoom. Tap to return to fit"
        fitButton.addAction(UIAction { [weak self] _ in self?.pointer.setZoom(1, anchor: nil) }, for: .primaryActionTriggered)
        filesButton.configuration?.image = UIImage(systemName: "folder")
        filesButton.accessibilityLabel = "Files"
        filesButton.isHidden = true
        filesButton.addAction(UIAction { [weak self] _ in self?.run("window.voxlFiles && voxlFiles()") }, for: .primaryActionTriggered)
        moreButton.configuration?.image = UIImage(systemName: "ellipsis.circle")
        moreButton.accessibilityLabel = "More"
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [
            UIAction(title: "Machines…", image: UIImage(systemName: "desktopcomputer")) { [weak self] _ in self?.showMachines() },
            UIAction(title: "Reconnect", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.failing = false
                self?.load()
            },
        ])
        tabs.axis = .horizontal
        tabs.spacing = 4
        nav.axis = .horizontal
        nav.spacing = 8
        nav.alignment = .center
        nav.isLayoutMarginsRelativeArrangement = true
        nav.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        for v in [machineButton, tabs, UIView(), fitButton, filesButton, moreButton] { nav.addArrangedSubview(v) }
        view.addSubview(nav)

        pad.accessibilityIdentifier = "pad"
        pad.backgroundColor = UIColor(white: 0.07, alpha: 1)
        pad.layer.cornerRadius = 14
        modeControl.selectedSegmentIndex = 0
        modeControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pointer.mode = self.modeControl.selectedSegmentIndex == 1 ? .direct : .trackpad
        }, for: .valueChanged)
        hint.numberOfLines = 0
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = UIColor(white: 0.6, alpha: 1)
        pad.addSubview(modeControl)
        pad.addSubview(hint)
        view.addSubview(pad)
        keyBar.run = { [weak self] in self?.run($0) }
        keyBar.onKeyboard = { [weak self] in self?.toggleKeyboard() }
        view.addSubview(keyBar)
        pointer.run = { [weak self] in self?.run($0) }
        pointer.onChange = { [weak self] in self?.updateNav() }
        pointer.attach(picture: touchLayer, pad: pad)

        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.keyboardMoved(note)
            }
        }

        let hinge = UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            if let h = update.hinge {
                let status = ["unknown", "closed", "partiallyOpen", "fullyOpen"][max(0, min(3, h.status.rawValue))]
                TestLog.shared.add("hinge", ["status": status, "degrees": Double(h.angle * 180 / .pi).rounded()])
            } else {
                TestLog.shared.add("hinge", ["status": "none"])
            }
            self.view.setNeedsLayout()
        }
        view.addInteraction(hinge)

        let last = Store.last
        machineIndex = machines.firstIndex { $0.name == last.machine } ?? 0
        row = min(max(0, last.row), max(0, (machine?.screens.count ?? 1) - 1))
        updateNav()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if machines.isEmpty { showCover("No machines yet.", button: "Add a machine", action: .machines) }
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let division = view.reservedRegions(kind: .division).first { $0.isActive }?.frame
        if division != fold || !laidOut {
            fold = division
            laidOut = true
            logRegions()
        }
        let f = Layout.frames(size: view.bounds.size, safe: view.safeAreaInsets, fold: fold,
                              keyboardTop: keyboardTop, aspect: aspect)
        nav.frame = f.nav
        // Keep the tabs clear of a camera over the screen (the outer screen's is always there).
        var lead: CGFloat = 8, trail: CGFloat = 8
        for r in view.reservedRegions(kind: .occlusion) where r.isActive && r.frame.intersects(f.nav) {
            if r.frame.midX > f.nav.midX { trail = max(trail, f.nav.maxX - r.frame.minX + 8) }
            else { lead = max(lead, r.frame.maxX - f.nav.minX + 8) }
        }
        nav.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: lead, bottom: 0, trailing: trail)
        let resized = pictureBox.frame.size != f.picture.size
        pictureBox.frame = f.picture
        cover.frame = f.picture
        web?.frame = pictureBox.bounds
        touchLayer.frame = pictureBox.bounds
        pad.frame = f.pad.insetBy(dx: 8, dy: 6)
        pad.isHidden = pad.frame.height < 40
        let controlHeight: CGFloat = 32
        modeControl.frame = CGRect(x: 12, y: 10, width: min(220, pad.bounds.width - 24), height: controlHeight)
        let hintWidth = max(0, pad.bounds.width - 24)
        let hintHeight = min(hint.sizeThatFits(CGSize(width: hintWidth, height: .greatestFiniteMagnitude)).height,
                             max(0, pad.bounds.height - controlHeight - 22))
        hint.frame = CGRect(x: 12, y: 10 + controlHeight + 8, width: hintWidth, height: hintHeight)
        keyBar.frame = f.keys
        if resized { pointer.apply() }
        if f != laidOutFrames {
            laidOutFrames = f
            let r = { (c: CGRect) in [c.minX, c.minY, c.width, c.height] }
            TestLog.shared.add("layout", ["nav": r(f.nav), "picture": r(f.picture), "pad": r(f.pad), "keys": r(f.keys),
                                          "margins": [lead, trail], "keyboardTop": keyboardTop ?? -1])
        }
    }

    /// The iPhone keyboard came, went or moved: the key bar sits on it.
    func keyboardMoved(_ note: Notification) {
        let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let frame = view.convert(end, from: nil)
        keyboardTop = note.name == UIResponder.keyboardWillHideNotification || frame.minY >= view.bounds.maxY
            ? nil : frame.minY
        UIView.animate(withDuration: 0.25) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    func run(_ js: String) { web?.evaluateJavaScript(js, completionHandler: nil) }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.logRegions() }
    }

    /// The window, its safe area and every reserved region (the fold, the cameras), active or not.
    func logRegions() {
        let all = view.reservedRegions(kind: .division, options: .includeInactive)
            + view.reservedRegions(kind: .occlusion, options: .includeInactive)
        let s = view.safeAreaInsets
        TestLog.shared.add("window", [
            "w": view.bounds.width, "h": view.bounds.height,
            "screen": [view.window?.screen.bounds.width ?? 0, view.window?.screen.bounds.height ?? 0],
            "safe": [s.top, s.left, s.bottom, s.right],
            "orientation": view.window?.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? 0,
            "regions": all.map { r in
                ["kind": r.kind == .division ? "division" : "occlusion", "active": r.isActive,
                 "frame": [r.frame.minX, r.frame.minY, r.frame.width, r.frame.height],
                 "margins": [r.margins.top, r.margins.left, r.margins.bottom, r.margins.right]] as [String: Any]
            },
        ])
    }

    // MARK: Tabs

    func updateNav() {
        machineButton.configuration?.title = machine?.name ?? "voxl"
        fitButton.configuration?.title = pointer.zoomText
        hint.text = hintText
        view.setNeedsLayout()
        machineButton.menu = UIMenu(children: machines.enumerated().map { i, m in
            UIAction(title: m.name, state: i == machineIndex ? .on : .off) { [weak self] _ in self?.pick(machine: i) }
        })
        tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, s) in (machine?.screens ?? []).enumerated() where (machine?.screens.count ?? 0) > 1 {
            var c: UIButton.Configuration = i == row ? .filled() : .gray()
            c.title = "\(i + 1) · \(s.name)"
            c.buttonSize = .small
            c.titleLineBreakMode = .byTruncatingTail
            let b = UIButton(configuration: c)
            b.isSelected = i == row
            b.titleLabel?.numberOfLines = 1
            b.addAction(UIAction { [weak self] _ in self?.go(to: i) }, for: .primaryActionTriggered)
            tabs.addArrangedSubview(b)
        }
    }

    func pick(machine i: Int) {
        guard i != machineIndex else { return }
        machineIndex = i
        row = 0
        switched()
    }

    /// A tab or F1..F9: screen n, never another by itself.
    func go(to n: Int) {
        guard let machine, n < machine.screens.count, n != row else { return }
        row = n
        switched()
    }

    func switched() {
        if let loaded { views[loaded.absoluteString] = pointer.state }
        Store.last = (machine?.name ?? "", row)
        release()
        keyboardShown = false
        failing = false
        updateNav()
        TestLog.shared.add("switch", ["to": label])
        load()
    }

    override var keyCommands: [UIKeyCommand]? {
        let f = [UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4, UIKeyCommand.f5,
                 UIKeyCommand.f6, UIKeyCommand.f7, UIKeyCommand.f8, UIKeyCommand.f9]
        return f.prefix(machine?.screens.count ?? 0).map { input in
            let c = UIKeyCommand(input: input, modifierFlags: [], action: #selector(fKey(_:)))
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }

    @objc func fKey(_ c: UIKeyCommand) {
        let f = [UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4, UIKeyCommand.f5,
                 UIKeyCommand.f6, UIKeyCommand.f7, UIKeyCommand.f8, UIKeyCommand.f9]
        if let n = f.firstIndex(where: { $0 == c.input }) { go(to: n) }
    }

    // MARK: Connecting

    func newWebView() {
        if let old = web {
            old.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            old.navigationDelegate = nil
            old.uiDelegate = nil
            old.stopLoading()
            old.removeFromSuperview()
        }
        let w = WKWebView(frame: pictureBox.bounds, configuration: config)
        w.isOpaque = false
        w.backgroundColor = .black
        w.underPageBackgroundColor = .black
        w.scrollView.isScrollEnabled = false
        w.scrollView.bounces = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.navigationDelegate = self
        w.uiDelegate = self
        w.isInspectable = true
        pictureBox.insertSubview(w, at: 0)
        w.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        web = w
        muted = nil
    }

    func load() {
        retryLater?.cancel()
        retryLater = nil
        guard let screen else { return }
        if web == nil || committed { newWebView() }
        let url = screen.page
        loaded = url
        answered = false
        committed = false
        hello = false
        picture = false
        tooWide = false
        tooWideLater?.cancel()
        needsPassword = false
        reconnecting = false
        keyBar.setArmed([])
        if !failing { showCover(label) }
        TestLog.shared.add("load", ["screen": label])
        waitThenCheck()
        watchHello()
        web?.load(URLRequest(url: url))
    }

    /// Lets the page go, so its stream stops: 30 s into the background.
    func closePage() {
        guard let w = web else { return }
        if let loaded { views[loaded.absoluteString] = pointer.state }
        w.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        w.navigationDelegate = nil
        w.stopLoading()
        w.removeFromSuperview()
        web = nil
        loaded = nil
        committed = false
        [waitLater, retryLater, helloLater, tooWideLater].forEach { $0?.cancel() }
        TestLog.shared.add("closed")
    }

    func waitThenCheck() {
        waitLater?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.waited() }
        waitLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// 3 s after a try: no answer yet means the note, and a new try 10 s into this one.
    func waited() {
        if answered { return }
        notAnswering()
        guard retryLater == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.answered else { return }
            self.load()
        }
        retryLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    /// 10 s from a load, or from the page losing its socket, with no hello: a fresh web view.
    func watchHello() {
        helloLater?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hello, self.answered else { return }
            TestLog.shared.add("noHello")
            self.load()
        }
        helloLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func notAnswering() {
        failing = true
        var other: String?
        if let m = machine, m.screens.count > 1 {
            let o = row == 0 ? 1 : 0
            other = "Show \(o + 1) · \(m.screens[o].name)"
        }
        showCover("\(screen?.name ?? "") isn't answering. Trying again every 3 s.", button: other,
                  action: other == nil ? .none : .otherScreen, dim: true)
    }

    func retry(_ why: String) {
        TestLog.shared.add("retry", ["why": why])
        notAnswering()
        retryLater?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load() }
        retryLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// The cover with this text, and what its button (if any) does.
    func showCover(_ text: String, button: String? = nil, action: CoverAction = .none, dim: Bool = false) {
        coverAction = button == nil ? .none : action
        cover.show(text, button: button, dim: dim)
    }

    func coverButton() {
        switch coverAction {
        case .none: return
        case .machines: return showMachines()
        case .signIn: return load()
        case .otherScreen: return go(to: row == 0 ? 1 : 0)
        case .sharp: break
        }
        // The picture is wider than this app plays: this screen asks for Sharp from now on.
        if let screen, screen.sharp == nil {
            var list = Store.machines
            if let i = list.firstIndex(where: { $0.name == machine?.name }), list[i].screens.indices.contains(row) {
                list[i].screens[row] = screen.withSharp
                Store.machines = list
                machines = list
            }
        }
        load()
    }

    // MARK: Machines

    func showMachines() {
        let list = MachinesController()
        list.onChange = { [weak self] in self?.machinesChanged() }
        let nav = UINavigationController(rootViewController: list)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    /// The saved list changed (the Machines screen, or a link): keep the screen on view if it's still
    /// there, else the first one; connect again only if what's on view changed.
    func machinesChanged() {
        let before = screen?.page
        let name = machine?.name
        machines = Store.machines
        machineIndex = machines.firstIndex { $0.name == name } ?? 0
        row = min(row, max(0, (machine?.screens.count ?? 1) - 1))
        updateNav()
        guard machine != nil else {
            closePage()
            return showCover("No machines yet.", button: "Add a machine", action: .machines)
        }
        if screen?.page != before || web == nil {
            failing = false
            load()
        }
    }

    /// A voxlviewer://add link: asks before adding its machines.
    func open(link: URL) {
        guard let new = Store.machines(in: link) else { return }
        let names = new.map { m in m.screens.count > 1 ? "\(m.name) (\(m.screens.count) screens)" : m.name }
        let a = UIAlertController(title: "Add machines?", message: names.joined(separator: ", "), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            Store.add(new)
            self?.machinesChanged()
        })
        (presentedViewController ?? self).present(a, animated: true)
    }

    func failed(_ error: Error) {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain, e.code != NSURLErrorCancelled else { return }
        retry(e.localizedDescription)
    }

    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { if w === web { failed(e) } }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { if w === web { failed(e) } }

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        guard w === web else { return }
        answered = true
        committed = true
        if failing {
            failing = false
            showCover(label)
        }
        updateAudio()
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        guard w === web else { return }
        TestLog.shared.add("webProcessEnded")
        load()
    }

    /// A voxl that keeps a password: Password answers, with the sheet if it must ask. Being asked is an answer.
    func webView(_ w: WKWebView, didReceive ch: URLAuthenticationChallenge,
                 completionHandler done: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if w === web {
            answered = true
            // Nothing tries again while the sheet waits for Dan; the watch starts over once he answers.
            helloLater?.cancel()
            waitLater?.cancel()
        }
        Password.answer(ch, over: self, name: label) { [weak self] d, c in
            if d == .useCredential, let self, w === self.web, !self.hello { self.watchHello() }
            // Cancelled: no new try every 10 s; the cover offers to sign in again.
            if d == .cancelAuthenticationChallenge, let self, w === self.web {
                self.helloLater?.cancel()
                self.waitLater?.cancel()
                self.needsPassword = true
                self.showCover("\(self.screen?.name ?? "This screen") needs its voxl password.", button: "Sign in", action: .signIn)
            }
            done(d, c)
        }
    }

    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse,
                 decisionHandler done: @escaping (WKNavigationResponsePolicy) -> Void) {
        if r.isForMainFrame, w === web { answered = true }
        let http = r.response as? HTTPURLResponse
        if r.isForMainFrame, let code = http?.statusCode, code >= 500 {
            done(.cancel)
            retry("voxl answered \(code).")
            return
        }
        let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        done(attachment || !r.canShowMIMEType ? .download : .allow)
    }

    // voxl's Files panel downloads with <a download> and attachment responses: the file goes to a
    // temporary folder, then iOS asks where to keep it.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler done: @escaping (WKNavigationActionPolicy) -> Void) {
        done(a.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ w: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }

    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String,
                  completionHandler done: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.isEmpty ? "download" : name)
        downloads[ObjectIdentifier(d)] = url
        done(url)
    }

    func downloadDidFinish(_ d: WKDownload) {
        guard let url = downloads.removeValue(forKey: ObjectIdentifier(d)) else { return }
        present(UIDocumentPickerViewController(forExporting: [url], asCopy: false), animated: true)
    }

    func download(_ d: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(d))
        TestLog.shared.add("downloadFailed", ["why": error.localizedDescription])
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.webView === web, let url = loaded, m.frameInfo.securityOrigin.host == url.host else { return }
        if m.name == "clip" {
            if active, let text = m.body as? String { UIPasteboard.general.string = text }
            if active, let png = (m.body as? [String: Any])?["png"] as? String, let data = Data(base64Encoded: png),
               let image = UIImage(data: data) { UIPasteboard.general.image = image }
            return
        }
        guard let body = m.body as? [String: Any], let t = body["t"] as? String else { return }
        switch t {
        case "hello":
            hello = true
            helloLater?.cancel()
            let w = (body["w"] as? Double) ?? 0, h = (body["h"] as? Double) ?? 0
            if w > 0, h > 0, abs(CGFloat(w / h) - aspect) > 0.001 {
                aspect = CGFloat(w / h)
                view.setNeedsLayout()
            }
            if w > 0, h > 0 {
                let size = CGSize(width: w, height: h)
                if let saved = views[url.absoluteString], saved.desk == size { pointer.state = saved } else { pointer.reset(desk: size) }
            }
            TestLog.shared.add("hello", ["w": w, "h": h, "os": body["os"] as? String ?? ""])
            // Every connection first hears the screen's current size, and Full until this page's Sharp
            // request lands (about half a second, measured on the Duo): too wide counts only if it stays.
            tooWide = w > 4096
            tooWideLater?.cancel()
            if tooWide {
                let name = screen?.name ?? ""
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.tooWide else { return }
                    self.showCover("Another viewer asked \(name) for Full (\(Int(w)) px wide). This app plays up to Sharp (4096).",
                                   button: "Ask for Sharp", action: .sharp)
                }
                tooWideLater = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            } else if picture {
                cover.hide()
            } else if coverAction == .sharp {
                // Sharp again before a frame: the cover goes back to saying it connects.
                showCover(label)
            }
            // A modifier tapped on the bar while this page loaded reaches it now.
            keyBar.resend()
        case "picture":
            picture = true
            failing = false
            waitLater?.cancel()
            if !tooWide { cover.hide() }
            focusKeys()
            TestLog.shared.add("picture", ["screen": label])
            if TestLog.shared.on {
                web?.evaluateJavaScript("navigator.audioSession ? navigator.audioSession.type : 'none'") { r, _ in
                    TestLog.shared.add("session", ["type": r as? String ?? "?"])
                }
            }
        case "status":
            let s = body["s"] as? String ?? ""
            TestLog.shared.add("socket", ["s": s])
            if s == "closed" {
                hello = false
                reconnecting = true
                watchHello()
            } else if s == "open", reconnecting {
                reconnecting = false
                release()
            }
        case "stats":
            stats = body
        case "sent":
            TestLog.shared.add("sent", ["d": body["d"] as? String ?? ""])
        case "cursor":
            pointer.setImage(url: body["url"] as? String,
                             hotspot: CGPoint(x: body["hx"] as? Double ?? 0, y: body["hy"] as? Double ?? 0))
            pointer.cursorView.isHidden = body["none"] as? Bool ?? false
        case "armed":
            keyBar.setArmed(body["mods"] as? [String] ?? [])
        case "files":
            filesButton.isHidden = !(body["available"] as? Bool ?? false)
            touchLayer.isHidden = body["open"] as? Bool ?? false
        case "log":
            TestLog.shared.add("pageLog", ["s": body["s"] as? String ?? ""])
        case "audio":
            audioState = body["s"] as? String ?? ""
            TestLog.shared.add("audio", ["state": audioState, "muted": muted ?? true])
        default: break
        }
    }

    // MARK: Keys

    /// Hardware keys reach voxl from the first press: the web view takes the keyboard focus and
    /// voxl's #kbd keeps it, with the iPhone keyboard hidden until asked for.
    func focusKeys() {
        guard let web else { return }
        web.becomeFirstResponder()
        web.evaluateJavaScript("window.voxlKeyboard && window.voxlKeyboard(\(keyboardShown))") { r, _ in
            TestLog.shared.add("focus", ["ok": (r as? Bool) ?? false, "keyboard": self.keyboardShown])
        }
    }

    func toggleKeyboard() {
        keyboardShown.toggle()
        focusKeys()
    }

    /// Lets go of every key the page holds down (voxl's own release-all).
    func release() {
        run("window.voxlRelease && window.voxlRelease()")
        keyBar.setArmed([])
    }

    // MARK: Sound, the idle timer, the background

    func input() {
        let back = Date().timeIntervalSince(lastInput) >= 300
        lastInput = Date()
        if back { updateAudio() }
    }

    var recentInput: Bool { Date().timeIntervalSince(lastInput) < 300 }

    /// Sound plays while the app is in front and was touched or typed in within 5 minutes, the
    /// desktop viewers' rule; a phone propped beside the Mac it shows goes quiet.
    func updateAudio() {
        guard let web else { return }
        let audible = committed && active && recentInput
        guard muted != !audible else { return }
        muted = !audible
        web.setAllMediaPlaybackSuspended(!audible, completionHandler: nil)
        // Playback ignores the silent switch but stops other apps' audio; ambient mixes with them.
        web.evaluateJavaScript("window.voxlAudioSession && window.voxlAudioSession('\(audible ? "playback" : "ambient")')") { r, _ in
            TestLog.shared.add("mute", ["muted": !audible, "session": r as? String ?? "?"])
        }
    }

    /// The screen stays on while the picture plays and someone used the app in the last 5 minutes
    /// (a test build: also its first 15 minutes, for the heat run).
    func updateIdle() {
        let heatRun = TestLog.shared.on && Date().timeIntervalSince(TestLog.shared.start) < 15 * 60
        let on = picture && active && (recentInput || heatRun)
        if UIApplication.shared.isIdleTimerDisabled != on { UIApplication.shared.isIdleTimerDisabled = on }
    }

    /// Opening the app is a touch on the phone too.
    func becameActive() {
        active = true
        input()
        closeLater?.cancel()
        endBackgroundTask()
        TestLog.shared.add("active")
        if web == nil { load() } else if picture { focusKeys() }
        updateAudio()
        updateIdle()
    }

    func resignedActive() {
        active = false
        release()
        updateAudio()
        updateIdle()
        TestLog.shared.add("inactive")
    }

    func enteredBackground() {
        TestLog.shared.add("background")
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.closePage()
            self?.endBackgroundTask()
        }
        let work = DispatchWorkItem { [weak self] in
            self?.closePage()
            TestLog.shared.flush { self?.endBackgroundTask() }
        }
        closeLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        TestLog.shared.flush()
    }

    func enteringForeground() {
        closeLater?.cancel()
        TestLog.shared.add("foreground")
    }

    func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func tick() {
        ticks += 1
        updateAudio()
        updateIdle()
        if TestLog.shared.on {
            if ticks % 5 == 0, picture, active { TestLog.shared.add("stats", stats) }
            if ticks % 30 == 1 { TestLog.shared.health() }
        }
        showPanel()
    }

    var hintText: String {
        pointer.mode == .trackpad
            ? "One finger moves the cursor · tap clicks · two fingers scroll · pinch zooms"
            : "Touch the picture where you mean · this pad still moves the cursor"
    }

    /// A test build adds what it measures under the hint.
    func showPanel() {
        guard TestLog.shared.on else { return }
        let p = ProcessInfo.processInfo
        let heat = ["nominal", "fair", "serious", "critical"][min(3, p.thermalState.rawValue)]
        let fps = (stats["fps"] as? Double) ?? 0, ms = (stats["decodeMs"] as? Double) ?? 0
        let mbps = ((stats["kbps"] as? Double) ?? 0) / 1000
        hint.text = hintText + "\n\nTest build · log \(TestLog.shared.sent) sent, \(TestLog.shared.failures) failed · "
            + String(format: "%.0f fps · decode %.1f ms · %.1f Mbps", fps, ms, mbps)
            + " · heat \(heat) · sound \(muted == false ? "on" : "off")"
        view.setNeedsLayout()
    }
}

/// Black over the picture until it plays, with what's happening; it eats touches meanwhile.
final class Cover: UIView {
    let text = UILabel()
    let button = UIButton(configuration: .filled())
    var onButton: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        text.textColor = UIColor(white: 0.93, alpha: 1)
        text.font = .systemFont(ofSize: 17, weight: .medium)
        text.numberOfLines = 0
        text.textAlignment = .center
        button.addAction(UIAction { [weak self] _ in self?.onButton?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [text, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ message: String, button title: String? = nil, dim: Bool = false) {
        TestLog.shared.add("cover", ["text": message, "button": title ?? ""])
        text.text = message
        button.configuration?.title = title
        button.configuration?.baseBackgroundColor = dim ? UIColor(white: 0.18, alpha: 1) : .systemBlue
        button.isHidden = title == nil
        isHidden = false
    }

    func hide() {
        if !isHidden { TestLog.shared.add("cover", ["hidden": true]) }
        isHidden = true
    }
}
