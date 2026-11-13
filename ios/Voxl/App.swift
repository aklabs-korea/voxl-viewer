import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    let viewer = ViewerController()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = ViewerWindow(windowScene: scene)
        window.onInput = { [weak viewer] in viewer?.input() }
        window.rootViewController = viewer
        window.makeKeyAndVisible()
        self.window = window
        TestLog.shared.device()
        if let link = options.urlContexts.first?.url { viewer.open(link: link) }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let link = contexts.first?.url { viewer.open(link: link) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) { viewer.becameActive() }
    func sceneWillResignActive(_ scene: UIScene) { viewer.resignedActive() }
    func sceneDidEnterBackground(_ scene: UIScene) { viewer.enteredBackground() }
    func sceneWillEnterForeground(_ scene: UIScene) { viewer.enteringForeground() }
}

/// Sees every touch and key press first, for the sound rule (input in the last 5 minutes) and the
/// test log. Key presses are logged by name only for F-keys, modifiers, Esc, Caps Lock and the
/// Korean/English keys; every other key is just "key".
final class ViewerWindow: UIWindow {
    var onInput: (() -> Void)?

    override func sendEvent(_ event: UIEvent) {
        switch event.type {
        case .touches:
            if event.allTouches?.contains(where: { $0.phase == .began }) == true {
                onInput?()
                for t in event.allTouches ?? [] where t.phase == .began {
                    let p = t.location(in: self)
                    TestLog.shared.add("touch", ["x": p.x, "y": p.y, "view": t.view.map { String(describing: type(of: $0)) } ?? "none",
                                                 "id": t.view?.accessibilityIdentifier ?? "", "n": event.allTouches?.count ?? 0])
                }
            }
        case .presses:
            if let presses = (event as? UIPressesEvent)?.allPresses {
                if presses.contains(where: { $0.phase == .began }) { onInput?() }
                for p in presses where p.phase == .began || p.phase == .ended {
                    guard let key = p.key else { continue }
                    TestLog.shared.add("press", ["key": ViewerWindow.name(key.keyCode), "down": p.phase == .began,
                                                 "mods": ViewerWindow.mods(key.modifierFlags)])
                }
            }
        default: break
        }
        super.sendEvent(event)
    }

    static func name(_ code: UIKeyboardHIDUsage) -> String {
        let f: [UIKeyboardHIDUsage] = [.keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
                                       .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12]
        if let i = f.firstIndex(of: code) { return "F\(i + 1)" }
        switch code {
        case .keyboardEscape: return "Esc"
        case .keyboardCapsLock: return "CapsLock"
        case .keyboardLANG1: return "Hangul"
        case .keyboardLANG2: return "Hanja"
        case .keyboardLeftGUI, .keyboardRightGUI: return "Cmd"
        case .keyboardLeftAlt, .keyboardRightAlt: return "Option"
        case .keyboardLeftControl, .keyboardRightControl: return "Control"
        case .keyboardLeftShift, .keyboardRightShift: return "Shift"
        default: return "key"
        }
    }

    static func mods(_ m: UIKeyModifierFlags) -> String {
        var s = ""
        if m.contains(.command) { s += "Cmd " }
        if m.contains(.alternate) { s += "Option " }
        if m.contains(.control) { s += "Control " }
        if m.contains(.shift) { s += "Shift " }
        if m.contains(.alphaShift) { s += "CapsLock " }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
