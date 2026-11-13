import os
import UIKit

/// Test builds only (VoxlTestLog in Info.plist, set by ios/build.sh): what the phone measures, sent
/// to the build machine every 10 s as JSON, so the test on the iPhone Duo needs nobody to read the
/// screen. It never records key letters or anything the page shows.
final class TestLog {
    static let shared = TestLog()
    let url: URL?
    let session = String(UUID().uuidString.prefix(8))
    let start = Date()
    private var pending: [[String: Any]] = []
    private var sending = false
    private(set) var sent = 0, failures = 0
    private var timer: Timer?
    private let stamp = ISO8601DateFormatter()

    var on: Bool { url != nil }

    private init() {
        let text = Bundle.main.object(forInfoDictionaryKey: "VoxlTestLog") as? String ?? ""
        url = text.isEmpty ? nil : URL(string: text)
        guard on else { return }
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.flush() }
    }

    func add(_ kind: String, _ fields: [String: Any] = [:]) {
        guard on else { return }
        var e = fields.compactMapValues(clean)
        e["k"] = kind
        e["t"] = (Date().timeIntervalSince(start) * 1000).rounded() / 1000
        e["at"] = stamp.string(from: Date())
        pending.append(e)
        if pending.count > 5000 { pending.removeFirst(pending.count - 5000) }
    }

    /// JSON can't hold NaN or infinity; nested values are cleaned the same way.
    private func clean(_ v: Any) -> Any? {
        switch v {
        case let d as Double: return d.isFinite ? d : nil
        case let f as CGFloat: return f.isFinite ? Double(f) : nil
        case let a as [Any]: return a.compactMap(clean)
        case let m as [String: Any]: return m.compactMapValues(clean)
        default: return v
        }
    }

    func flush(_ done: (() -> Void)? = nil) {
        guard let url, !sending, !pending.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: ["session": session, "events": pending]) else {
            done?()
            return
        }
        let count = pending.count
        sending = true
        var r = URLRequest(url: url, timeoutInterval: 8)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        URLSession.shared.dataTask(with: r) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sending = false
                if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.pending.removeFirst(min(count, self.pending.count))
                    self.sent += count
                } else {
                    self.failures += 1
                }
                done?()
            }
        }.resume()
    }

    /// The phone's model id ("iPhone19,4"), iOS and the screens, once per launch.
    func device() {
        var u = utsname()
        uname(&u)
        let model = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        add("device", ["model": model, "ios": UIDevice.current.systemVersion,
                       "app": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""])
    }

    /// Heat, battery and memory: every 30 s while the app is in front.
    func health() {
        let p = ProcessInfo.processInfo
        let heat = ["nominal", "fair", "serious", "critical"][min(3, p.thermalState.rawValue)]
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = ["unknown", "unplugged", "charging", "full"][min(3, UIDevice.current.batteryState.rawValue)]
        add("health", ["heat": heat, "battery": Double(UIDevice.current.batteryLevel), "power": state,
                       "lowPower": p.isLowPowerModeEnabled, "memMB": Double(os_proc_available_memory()) / 1_048_576])
    }
}
