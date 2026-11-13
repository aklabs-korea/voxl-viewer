import UIKit

/// The Machines screen: add a machine by its voxl link, name it, give it more screens (in order:
/// screen N is F-key N and tab N), turn Sharp on for a screen wider than this device plays, reorder
/// and remove. Every change is saved at once.
final class MachinesController: UITableViewController {
    var onChange: () -> Void = {}

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Machines"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.addMachine() }),
            editButtonItem,
        ]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    var machines: [Machine] { Store.machines }

    func save(_ list: [Machine]) {
        Store.machines = list
        onChange()
    }

    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { machines.count }

    override func tableView(_ t: UITableView, titleForFooterInSection s: Int) -> String? {
        machines.isEmpty
            ? "Tap + and paste a voxl link, such as https://your-mac.your-tailnet.ts.net:6901/. The device needs to reach it (Tailscale)."
            : nil
    }

    override func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let m = machines[i.row]
        c.textLabel?.text = m.name
        c.detailTextLabel?.text = m.screens.map(\.name).joined(separator: " · ")
        c.accessoryType = .disclosureIndicator
        return c
    }

    override func tableView(_ t: UITableView, didSelectRowAt i: IndexPath) {
        let e = MachineEditor(index: i.row)
        e.onChange = onChange
        navigationController?.pushViewController(e, animated: true)
    }

    override func tableView(_ t: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt i: IndexPath) {
        guard style == .delete else { return }
        var list = machines
        list.remove(at: i.row)
        save(list)
        t.deleteRows(at: [i], with: .automatic)
    }

    override func tableView(_ t: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
        var list = machines
        list.insert(list.remove(at: from.row), at: to.row)
        save(list)
    }

    func addMachine() {
        ask(self, title: "Add a machine", fields: [("Name", ""), ("voxl link", "https://")], done: "Add") { [weak self] v in
            guard let self, let url = voxlURL(v[1]) else { return "That isn't a link (https://…)." }
            let name = v[0].trimmingCharacters(in: .whitespaces)
            let m = Machine(name: name.isEmpty ? hostPort(url) : name, screens: [Screen(name: hostPort(url), url: url)])
            self.save(self.machines + [m])
            self.tableView.reloadData()
            return nil
        }
    }
}

/// One machine: its name, and its screens in order.
final class MachineEditor: UITableViewController {
    let index: Int
    var onChange: () -> Void = {}

    init(index: Int) {
        self.index = index
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    var machine: Machine? { Store.machines.indices.contains(index) ? Store.machines[index] : nil }

    func save(_ m: Machine) {
        var list = Store.machines
        guard list.indices.contains(index) else { return }
        list[index] = m
        Store.machines = list
        onChange()
        title = m.name
        tableView.reloadData()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = machine?.name
        navigationItem.rightBarButtonItem = editButtonItem
    }

    override func numberOfSections(in t: UITableView) -> Int { 3 }

    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int {
        s == 1 ? machine?.screens.count ?? 0 : 1
    }

    override func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? { s == 1 ? "Screens" : nil }

    override func tableView(_ t: UITableView, titleForFooterInSection s: Int) -> String? {
        s == 1 ? "Screen N opens with tab N and F-key N. Sharp asks the screen for 4096 pixels across, for a screen wider than this device can play; it needs a voxl with Dan's capture-scale patch (stock voxl ignores it)." : nil
    }

    override func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard let m = machine else { return c }
        switch i.section {
        case 0:
            c.textLabel?.text = "Name"
            c.detailTextLabel?.text = m.name
            c.accessoryType = .disclosureIndicator
        case 1:
            let s = m.screens[i.row]
            c.textLabel?.text = "\(i.row + 1) · \(s.name)"
            c.detailTextLabel?.text = hostPort(s.url)
            let sharp = UISwitch()
            sharp.isOn = s.sharp != nil
            sharp.accessibilityLabel = "Sharp"
            sharp.addAction(UIAction { [weak self] _ in self?.setSharp(i.row, sharp.isOn) }, for: .valueChanged)
            let label = UILabel()
            label.text = "Sharp"
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            let stack = UIStackView(arrangedSubviews: [label, sharp])
            stack.spacing = 6
            stack.alignment = .center
            stack.frame.size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            c.accessoryView = stack
        default:
            c.textLabel?.text = "Add a screen"
            c.textLabel?.textColor = .tintColor
        }
        return c
    }

    func setSharp(_ row: Int, _ on: Bool) {
        guard var m = machine else { return }
        m.screens[row] = on ? m.screens[row].withSharp : Screen(name: m.screens[row].name, url: m.screens[row].url)
        save(m)
    }

    override func tableView(_ t: UITableView, didSelectRowAt i: IndexPath) {
        t.deselectRow(at: i, animated: true)
        guard var m = machine else { return }
        switch i.section {
        case 0:
            ask(self, title: "Name", fields: [("Name", m.name)], done: "Save") { [weak self] v in
                let name = v[0].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return "A name, please." }
                m.name = name
                self?.save(m)
                return nil
            }
        case 1:
            let s = m.screens[i.row]
            ask(self, title: "Screen \(i.row + 1)", fields: [("Name", s.name), ("voxl link", s.url.absoluteString)], done: "Save") { [weak self] v in
                guard let url = voxlURL(v[1]) else { return "That isn't a link (https://…)." }
                let name = v[0].trimmingCharacters(in: .whitespaces)
                let screen = Screen(name: name.isEmpty ? hostPort(url) : name, url: url)
                m.screens[i.row] = s.sharp != nil ? screen.withSharp : screen
                self?.save(m)
                return nil
            }
        default:
            ask(self, title: "Add a screen", fields: [("Name", ""), ("voxl link", "https://")], done: "Add") { [weak self] v in
                guard let url = voxlURL(v[1]) else { return "That isn't a link (https://…)." }
                let name = v[0].trimmingCharacters(in: .whitespaces)
                m.screens.append(Screen(name: name.isEmpty ? hostPort(url) : name, url: url))
                self?.save(m)
                return nil
            }
        }
    }

    override func tableView(_ t: UITableView, canEditRowAt i: IndexPath) -> Bool {
        i.section == 1 && (machine?.screens.count ?? 0) > 1
    }

    override func tableView(_ t: UITableView, canMoveRowAt i: IndexPath) -> Bool { i.section == 1 }

    override func tableView(_ t: UITableView, targetIndexPathForMoveFromRowAt from: IndexPath,
                            toProposedIndexPath to: IndexPath) -> IndexPath {
        to.section == 1 ? to : from
    }

    override func tableView(_ t: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt i: IndexPath) {
        guard style == .delete, var m = machine, m.screens.count > 1 else { return }
        m.screens.remove(at: i.row)
        save(m)
    }

    override func tableView(_ t: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
        guard var m = machine else { return }
        m.screens.insert(m.screens.remove(at: from.row), at: to.row)
        save(m)
    }
}

/// An alert with text fields. done returns nil when the values are good, or what's wrong (the alert
/// comes back with it).
func ask(_ host: UIViewController, title: String, message: String? = nil, fields: [(String, String)], done: String,
         check: @escaping ([String]) -> String?) {
    let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
    for (placeholder, value) in fields {
        a.addTextField { f in
            f.placeholder = placeholder
            f.text = value
            f.clearButtonMode = .whileEditing
            if placeholder.contains("link") {
                f.keyboardType = .URL
                f.autocapitalizationType = .none
                f.autocorrectionType = .no
            }
        }
    }
    a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    a.addAction(UIAlertAction(title: done, style: .default) { _ in
        let values = a.textFields?.map { $0.text ?? "" } ?? []
        if let problem = check(values) {
            ask(host, title: title, message: problem, fields: zip(fields.map(\.0), values).map { ($0, $1) }, done: done, check: check)
        }
    })
    host.present(a, animated: true)
}
