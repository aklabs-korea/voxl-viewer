import UIKit

/// The Mac keys the iPhone keyboard lacks: Esc, Tab, ⌘⌥⌃⇧ for the next key or click only, the
/// arrows, F1-F12, the Mac shortcuts iOS keeps for itself, Paste, and the iPhone keyboard. Each key
/// goes into voxl's own key path in the page (Page.input) as a key event, so voxl alone holds which
/// keys are down. What fits depends on the width: the rest is under ⋯.
final class KeyBar: UIView {
    /// Runs a call in the page.
    var run: (String) -> Void = { _ in }
    var onKeyboard: () -> Void = {}
    private(set) var armed: [String] = []
    private let stack = UIStackView()
    private var built: CGFloat = -1
    private var modButtons: [String: UIButton] = [:]
    private let tick = UISelectionFeedbackGenerator()

    private static let mods: [(code: String, label: String, name: String)] = [
        ("MetaLeft", "⌘", "Command"), ("AltLeft", "⌥", "Option"), ("ControlLeft", "⌃", "Control"), ("ShiftLeft", "⇧", "Shift"),
    ]
    private static let arrows: [(key: String, label: String, name: String)] = [
        ("ArrowLeft", "←", "Left arrow"), ("ArrowUp", "↑", "Up arrow"), ("ArrowDown", "↓", "Down arrow"), ("ArrowRight", "→", "Right arrow"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        addSubview(stack)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: ["public.plain-text", "public.text"])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.frame = bounds.insetBy(dx: 8, dy: 6)
        let w = bounds.width
        let size: CGFloat = w >= 720 ? 2 : w >= 560 ? 1 : 0
        if size != built {
            built = size
            build(size)
        }
    }

    /// 2: everything in a row; 1: F-keys, Mac keys and Paste under ⋯; 0: Tab and the arrows too.
    private func build(_ size: CGFloat) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        modButtons = [:]
        stack.addArrangedSubview(key("esc", name: "Escape") { [weak self] in self?.tap("Escape", "Escape") })
        if size >= 1 { stack.addArrangedSubview(key("tab", name: "Tab") { [weak self] in self?.tap("Tab", "Tab") }) }
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        for m in KeyBar.mods {
            let b = key(m.label, name: "\(m.name), for the next key") { [weak self] in self?.toggle(m.code) }
            modButtons[m.code] = b
            stack.addArrangedSubview(b)
        }
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        if size >= 1 {
            for a in KeyBar.arrows {
                stack.addArrangedSubview(key(a.label, name: a.name) { [weak self] in self?.tap(a.key, a.key) })
            }
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        if size >= 2 {
            stack.addArrangedSubview(menuButton("F1–F12", name: "F-keys", menu: fKeys()))
            stack.addArrangedSubview(menuButton("Mac keys", name: "Mac keys", menu: macKeys()))
            let paste = UIPasteControl(configuration: {
                let c = UIPasteControl.Configuration()
                c.displayMode = .labelOnly
                c.cornerStyle = .medium
                return c
            }())
            paste.target = self
            stack.addArrangedSubview(paste)
        } else {
            var items: [UIMenuElement] = []
            if size < 1 {
                items.append(UIAction(title: "Tab") { [weak self] _ in self?.tap("Tab", "Tab") })
                items.append(UIMenu(title: "Arrows", children: KeyBar.arrows.map { a in
                    UIAction(title: "\(a.label) \(a.name)") { [weak self] _ in self?.tap(a.key, a.key) }
                }))
            }
            items += [fKeys(), macKeys(), UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                if let text = UIPasteboard.general.string { self?.paste(text) }
            }]
            let more = menuButton("", name: size < 1 ? "More keys: tab, arrows, F-keys, Mac keys, Paste" : "More keys: F-keys, Mac keys, Paste",
                                  menu: UIMenu(children: items))
            more.configuration?.image = UIImage(systemName: "ellipsis")
            stack.addArrangedSubview(more)
        }
        let kb = key("", name: "Show or hide the keyboard") { [weak self] in self?.onKeyboard() }
        kb.configuration?.image = UIImage(systemName: "keyboard")
        stack.addArrangedSubview(kb)
        setArmed(armed)
    }

    private func key(_ label: String, name: String, _ action: @escaping () -> Void) -> UIButton {
        var c = UIButton.Configuration.gray()
        c.title = label.isEmpty ? nil : label
        c.buttonSize = .medium
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        c.titleLineBreakMode = .byClipping
        let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in
            self?.tick.selectionChanged()
            action()
        })
        b.accessibilityLabel = name
        b.titleLabel?.numberOfLines = 1
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    private func menuButton(_ label: String, name: String, menu: UIMenu) -> UIButton {
        let b = key(label, name: name) {}
        b.menu = menu
        b.showsMenuAsPrimaryAction = true
        return b
    }

    private func fKeys() -> UIMenu {
        UIMenu(title: "F1–F12", children: (1...12).map { n in
            UIAction(title: "F\(n)") { [weak self] _ in self?.tap("F\(n)", "F\(n)") }
        })
    }

    /// The Mac shortcuts iOS keeps for itself when typed on a hardware keyboard.
    private func macKeys() -> UIMenu {
        let chords: [(String, [String], String, String)] = [
            ("Spotlight  ⌘Space", ["MetaLeft"], " ", "Space"),
            ("App Switcher  ⌘Tab", ["MetaLeft"], "Tab", "Tab"),
            ("Mission Control  ⌃↑", ["ControlLeft"], "ArrowUp", "ArrowUp"),
            ("Show Desktop  ⌘F3", ["MetaLeft"], "F3", "F3"),
        ]
        return UIMenu(title: "Mac keys", children: chords.map { c in
            UIAction(title: c.0) { [weak self] _ in self?.chord(c.1, c.2, c.3) }
        })
    }

    private func js(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func tap(_ key: String, _ code: String) {
        run("window.voxlTap && voxlTap('\(js(key))', '\(code)')")
        setArmed([])
    }

    private func chord(_ mods: [String], _ key: String, _ code: String) {
        let list = mods.map { "'\($0)'" }.joined(separator: ",")
        run("window.voxlChord && voxlChord([\(list)], '\(js(key))', '\(code)')")
    }

    private func toggle(_ code: String) {
        var a = armed
        if let i = a.firstIndex(of: code) { a.remove(at: i) } else { a.append(code) }
        setArmed(a)
        run("window.voxlArm && voxlArm([\(a.map { "'\($0)'" }.joined(separator: ","))])")
    }

    /// The armed modifiers again, for a page that connected after they were tapped.
    func resend() {
        guard !armed.isEmpty else { return }
        run("window.voxlArm && voxlArm([\(armed.map { "'\($0)'" }.joined(separator: ","))])")
    }

    /// Lit while armed; the page says when the next key or click has used them.
    func setArmed(_ a: [String]) {
        armed = a
        for (code, b) in modButtons {
            var c: UIButton.Configuration = a.contains(code) ? .filled() : .gray()
            c.title = b.configuration?.title
            c.buttonSize = .medium
            c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            b.configuration = c
            b.accessibilityValue = a.contains(code) ? "on" : "off"
        }
    }

    func paste(_ text: String) {
        let quoted = (try? String(data: JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)) ?? "[\"\"]"
        run("window.voxlPaste && voxlPaste(\(quoted)[0])")
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let p = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = p.loadObject(ofClass: NSString.self) { [weak self] s, _ in
            guard let text = s as? String else { return }
            DispatchQueue.main.async { self?.paste(text) }
        }
    }
}
