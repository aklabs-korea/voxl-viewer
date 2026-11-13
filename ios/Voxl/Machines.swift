import Foundation

// The machines and their screens, as the desktop viewers keep them: a machine is its screens in the
// user's order, each a voxl URL with an optional Sharp URL, a smaller stream of the same screen. The
// app plays Sharp where a screen has one.
//
// The list lives on the device. It is filled in the Machines screen, or by a link
// voxlviewer://add?d=<base64url of [{name, screens: [{name, url, sharp}]}]>, the desktop viewers'
// machine-list shape; builds carry no machines.

struct Screen: Codable, Equatable {
    var name: String
    var url: URL
    var sharp: URL?

    /// What the app loads: Sharp where there is one.
    var page: URL { sharp ?? url }

    /// The same screen asked for 4096 pixels wide: `?scale=0.8` (pixels per point; 0.8 turns a
    /// 5120-wide screen at one pixel per point into 4096).
    var withSharp: Screen {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return self }
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "scale" } + [URLQueryItem(name: "scale", value: "0.8")]
        var s = self
        s.sharp = c.url
        return s
    }
}

struct Machine: Codable, Equatable {
    var name: String
    var screens: [Screen]
}

enum Store {
    private static let key = "machines"

    static var machines: [Machine] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([Machine].self, from: data) else { return [] }
            return list.filter { !$0.screens.isEmpty }
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// The machine and screen on view last, by name, so a reordered list still finds them.
    static var last: (machine: String, row: Int) {
        get {
            (UserDefaults.standard.string(forKey: "lastMachine") ?? "",
             UserDefaults.standard.integer(forKey: "lastRow"))
        }
        set {
            UserDefaults.standard.set(newValue.machine, forKey: "lastMachine")
            UserDefaults.standard.set(newValue.row, forKey: "lastRow")
        }
    }

    /// The machines in a voxlviewer://add link, or nil if it isn't one.
    static func machines(in link: URL) -> [Machine]? {
        guard link.scheme == "voxlviewer", link.host == "add",
              let d = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value
        else { return nil }
        var b64 = d.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let list = try? JSONDecoder().decode([Machine].self, from: data) else { return nil }
        let ok = list.filter { m in !m.screens.isEmpty && m.screens.allSatisfy { voxlURL($0.url.absoluteString) != nil } }
        return ok.isEmpty ? nil : ok
    }

    /// Adds machines; one with the same name as a saved machine replaces it.
    static func add(_ new: [Machine]) {
        var list = machines
        for m in new {
            if let i = list.firstIndex(where: { $0.name == m.name }) { list[i] = m } else { list.append(m) }
        }
        machines = list
    }
}

/// An http or https URL with a host, or nil. An empty path becomes "/".
func voxlURL(_ text: String) -> URL? {
    guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host?.isEmpty == false
    else { return nil }
    if c.path.isEmpty { c.path = "/" }
    return c.url
}

/// "host:port": a screen's name when none is given.
func hostPort(_ url: URL) -> String {
    let host = url.host ?? url.absoluteString
    return url.port.map { "\(host):\($0)" } ?? host
}
