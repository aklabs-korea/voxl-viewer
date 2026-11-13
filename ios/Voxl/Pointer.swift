import UIKit

/// The Mac's pointer on the phone: where it is (in desktop pixels), the zoom, the cursor the app
/// draws, and the gestures on the picture and on the pad under it. Every click, drag and scroll goes
/// to voxl's own mouse code in the page (Page.input); the app never sends voxl commands itself.
///
/// Trackpad (the default): one finger moves the cursor, a tap clicks at it, two taps double-click,
/// hold then drag drags, two fingers scroll, a two-finger tap right-clicks. Direct: the same, except
/// one finger on the picture acts where it touches (a tap clicks there, a drag drags). The pad is a
/// trackpad in both. Pinch zooms only the phone's view; a two-finger double tap goes back to fit.
///
/// A trackpad or mouse (an iPad's) points at the picture directly in both modes: moving it moves the
/// Mac's pointer there, a click clicks there, a secondary click right-clicks, dragging drags and
/// scrolling scrolls. The app hides iPadOS's own pointer over the picture and draws the Mac's.
final class Pointer: NSObject, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    enum Mode { case trackpad, direct }

    var mode: Mode = .trackpad {
        didSet {
            if dragging {
                send("up", 0)
                dragging = false
            }
            onChange?()
        }
    }
    /// The desktop's size in pixels, from voxl's hello.
    var desk = CGSize(width: 4096, height: 1728)
    /// Where the Mac's pointer is, in desktop pixels.
    var cursor = CGPoint(x: 2048, y: 864)
    /// The part of the desktop on view, as fractions of it: all of it, a half or a window (Parts.swift).
    private(set) var box = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// 1 is the whole part (fit); up to 8.
    private(set) var zoom: CGFloat = 1
    /// The top-left of what's on view, in desktop pixels.
    private(set) var origin = CGPoint.zero

    /// Runs a call in the page (evaluateJavaScript).
    var run: (String) -> Void = { _ in }
    /// Zoom or mode changed: the nav's Fit button and the pad's hint follow.
    var onChange: (() -> Void)?
    let cursorView = UIImageView(image: Pointer.arrow)
    private var hotspot = CGPoint(x: 1, y: 1)

    private weak var picture: UIView?
    private var dragging = false
    private var lastTap: (at: Date, point: CGPoint)?
    private var twoFinger: TwoFinger = .undecided
    private enum TwoFinger { case undecided, scroll, zoom }
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// The part in desktop pixels: the cursor and the view stay inside it.
    var area: CGRect {
        CGRect(x: box.minX * desk.width, y: box.minY * desk.height, width: box.width * desk.width, height: box.height * desk.height)
    }

    /// The part's shape, for the picture's box.
    var aspect: CGFloat { area.height > 0 ? area.width / area.height : 4096.0 / 1728.0 }

    /// Screen points per desktop pixel, at this zoom.
    private var k: CGFloat {
        guard let picture, area.width > 0 else { return 1 }
        return zoom * picture.bounds.width / area.width
    }

    /// The picture (the web view's box) and the pad take the gestures; the cursor is drawn over the picture.
    func attach(picture: UIView, pad: UIView) {
        self.picture = picture
        cursorView.isUserInteractionEnabled = false
        picture.addSubview(cursorView)
        for view in [picture, pad] { addGestures(to: view) }
        addPointerGestures(to: picture)
        place()
    }

    /// A trackpad or mouse on the picture. Finger gestures take fingers only (addGestures), so the two never mix.
    private func addPointerGestures(to view: UIView) {
        let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(pointerHover(_:)))
        let click = UITapGestureRecognizer(target: self, action: #selector(pointerClick(_:)))
        click.allowedTouchTypes = pointer
        click.buttonMaskRequired = .primary
        let right = UITapGestureRecognizer(target: self, action: #selector(pointerClick(_:)))
        right.allowedTouchTypes = pointer
        right.buttonMaskRequired = .secondary
        let drag = UIPanGestureRecognizer(target: self, action: #selector(pointerDrag(_:)))
        drag.allowedTouchTypes = pointer
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(pointerScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        for g in [hover, click, right, drag, scroll] as [UIGestureRecognizer] { view.addGestureRecognizer(g) }
        view.addInteraction(UIPointerInteraction(delegate: self))
    }

    func pointerInteraction(_ i: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

    @objc private func pointerHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed, let picture else { return }
        moveTo(deskPoint(g.location(in: picture)))
    }

    @objc private func pointerClick(_ g: UITapGestureRecognizer) {
        guard let picture else { return }
        moveTo(deskPoint(g.location(in: picture)))
        click(g.buttonMaskRequired == .secondary ? 2 : 0)
    }

    @objc private func pointerDrag(_ g: UIPanGestureRecognizer) {
        guard let picture else { return }
        let p = deskPoint(g.location(in: picture))
        switch g.state {
        case .began:
            moveTo(p)
            send("down", 0)
            dragging = true
        case .changed: moveTo(p)
        default:
            if dragging { send("up", 0) }
            dragging = false
        }
    }

    @objc private func pointerScroll(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed, let picture else { return }
        let d = g.translation(in: picture)
        g.setTranslation(.zero, in: picture)
        let at = deskPoint(g.location(in: picture))
        let x = desk.width > 0 ? at.x / desk.width : 0, y = desk.height > 0 ? at.y / desk.height : 0
        run("window.voxlWheel && voxlWheel(\(x), \(y), \(-d.x), \(-d.y))")
    }

    private func addGestures(to view: UIView) {
        let one = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        one.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 10
        let fit = UITapGestureRecognizer(target: self, action: #selector(fitTap(_:)))
        fit.numberOfTouchesRequired = 2
        fit.numberOfTapsRequired = 2
        let right = UITapGestureRecognizer(target: self, action: #selector(rightTap(_:)))
        right.numberOfTouchesRequired = 2
        right.require(toFail: fit)
        let two = UIPanGestureRecognizer(target: self, action: #selector(twoPan(_:)))
        two.minimumNumberOfTouches = 2
        two.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for g in [one, tap, hold, fit, right, two, pinch] as [UIGestureRecognizer] {
            g.delegate = self
            if g !== pinch { g.allowedTouchTypes = fingers }
            view.addGestureRecognizer(g)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Hold-then-drag needs both; pinch and two-finger scroll decide between them in twoPan/pinch.
        let pair = Set([ObjectIdentifier(type(of: g)), ObjectIdentifier(type(of: other))])
        return pair == Set([ObjectIdentifier(UIPanGestureRecognizer.self), ObjectIdentifier(UILongPressGestureRecognizer.self)])
            || pair == Set([ObjectIdentifier(UIPanGestureRecognizer.self), ObjectIdentifier(UIPinchGestureRecognizer.self)])
    }

    /// Where a touch on the picture is on the desktop. The pad has no position of its own.
    private func deskPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x / k, y: origin.y + p.y / k)
    }

    private func onPicture(_ g: UIGestureRecognizer) -> Bool { g.view === picture }
    private var direct: Bool { mode == .direct }

    // MARK: Gestures

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { TestLog.shared.add("gesture", ["g": "pan", "onPicture": onPicture(g)]) }
        if direct && onPicture(g) {
            let p = deskPoint(g.location(in: picture))
            switch g.state {
            case .began:
                moveTo(p)
                send("down", 0)
                dragging = true
                haptic.impactOccurred()
            case .changed: moveTo(p)
            default:
                if dragging { send("up", 0) }
                dragging = false
            }
            return
        }
        guard g.state == .changed || g.state == .ended else { return }
        let d = g.translation(in: g.view)
        g.setTranslation(.zero, in: g.view)
        // A little acceleration, for a 4096-pixel-wide desktop on a phone.
        let v = g.velocity(in: g.view)
        let gain = 1 + 1.5 * min(1, hypot(v.x, v.y) / 900)
        moveTo(CGPoint(x: cursor.x + d.x * gain / k, y: cursor.y + d.y * gain / k), follow: true)
    }

    @objc private func hold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard !(direct && onPicture(g)) else { return }
            send("down", 0)
            dragging = true
            haptic.impactOccurred()
        case .ended, .cancelled, .failed:
            if dragging { send("up", 0) }
            dragging = false
        default: break
        }
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        if direct && onPicture(g) {
            var p = deskPoint(g.location(in: picture))
            // The second tap of a double tap lands where the first did, so the Mac counts it.
            if let last = lastTap, Date().timeIntervalSince(last.at) < 0.4,
               hypot((p.x - last.point.x) * k, (p.y - last.point.y) * k) < 40 { p = last.point }
            lastTap = (Date(), p)
            moveTo(p)
        }
        click(0)
    }

    @objc private func rightTap(_ g: UITapGestureRecognizer) {
        TestLog.shared.add("gesture", ["g": "rightTap"])
        if direct && onPicture(g) { moveTo(deskPoint(g.location(in: picture))) }
        click(2)
    }

    @objc private func fitTap(_ g: UITapGestureRecognizer) { setZoom(1, anchor: nil) }

    @objc private func twoPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: if twoFinger == .undecided { twoFinger = .scroll }
        case .changed:
            guard twoFinger == .scroll else { return }
            let d = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            // The content follows the fingers.
            run("window.voxlWheel && voxlWheel(\(fx), \(fy), \(-d.x), \(-d.y))")
        default: twoFinger = .undecided
        }
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { TestLog.shared.add("gesture", ["g": "pinch"]) }
        switch g.state {
        case .changed:
            if twoFinger == .undecided, abs(log(g.scale)) > 0.08 { twoFinger = .zoom }
            guard twoFinger == .zoom, let picture else { return }
            let at = g.view === picture ? g.location(in: picture) : place(of: cursor)
            setZoom(zoom * g.scale, anchor: at)
            g.scale = 1
        case .ended, .cancelled, .failed: twoFinger = .undecided
        default: break
        }
    }

    // MARK: Moving, clicking, zooming

    private var fx: CGFloat { desk.width > 0 ? cursor.x / desk.width : 0 }
    private var fy: CGFloat { desk.height > 0 ? cursor.y / desk.height : 0 }

    private func send(_ type: String, _ button: Int) {
        if type != "move" {
            TestLog.shared.add("mouse", ["type": type, "button": button, "cursor": [cursor.x, cursor.y],
                                         "desk": [desk.width, desk.height], "zoom": zoom])
        }
        run("window.voxlMouse && voxlMouse('\(type)', \(fx), \(fy), \(button))")
    }

    private func click(_ button: Int) {
        send("down", button)
        send("up", button)
        haptic.impactOccurred()
    }

    /// Moves the Mac's pointer; follow keeps it on view while zoomed in (the view moves with it).
    func moveTo(_ p: CGPoint, follow: Bool = false) {
        cursor = inArea(p)
        if follow, zoom > 1, let picture {
            let w = picture.bounds.width / k, h = picture.bounds.height / k
            let margin = 24 / k
            var o = origin
            if cursor.x < o.x + margin { o.x = cursor.x - margin }
            if cursor.x > o.x + w - margin { o.x = cursor.x - w + margin }
            if cursor.y < o.y + margin { o.y = cursor.y - margin }
            if cursor.y > o.y + h - margin { o.y = cursor.y - h + margin }
            if o != origin { setOrigin(o) }
        }
        send("move", 0)
        place()
    }

    /// Zooms around anchor (a point in the picture; nil: its center).
    func setZoom(_ z: CGFloat, anchor: CGPoint?) {
        guard let picture else { return }
        let at = anchor ?? CGPoint(x: picture.bounds.midX, y: picture.bounds.midY)
        let fixed = deskPoint(at)
        zoom = min(max(1, z), 8)
        setOrigin(CGPoint(x: fixed.x - at.x / k, y: fixed.y - at.y / k))
        onChange?()
    }

    private func setOrigin(_ o: CGPoint) {
        guard let picture else { return }
        let w = picture.bounds.width / k, h = picture.bounds.height / k, a = area
        origin = CGPoint(x: min(max(a.minX, o.x), max(a.minX, a.maxX - w)), y: min(max(a.minY, o.y), max(a.minY, a.maxY - h)))
        apply()
    }

    /// The page's #surface follows the zoom; the cursor follows both.
    func apply() {
        if let picture {
            let w = picture.bounds.width / k, h = picture.bounds.height / k, a = area
            origin = CGPoint(x: min(max(a.minX, origin.x), max(a.minX, a.maxX - w)),
                             y: min(max(a.minY, origin.y), max(a.minY, a.maxY - h)))
        }
        let kk = k
        run("window.voxlZoom && voxlZoom(\(desk.width * kk), \(desk.height * kk), \(-origin.x * kk), \(-origin.y * kk))")
        place()
    }

    /// The nearest point to p inside the part.
    private func inArea(_ p: CGPoint) -> CGPoint {
        let a = area
        return CGPoint(x: min(max(a.minX, p.x), a.maxX - 1), y: min(max(a.minY, p.y), a.maxY - 1))
    }

    /// Shows part of the desktop (fractions of it), fitted to it, or (keepZoom) as zoomed in as before and
    /// kept inside it. The cursor stays in it; the Mac's pointer goes there with the next move or click.
    func show(box b: CGRect, keepZoom: Bool = false) {
        box = b
        if !keepZoom { zoom = 1 }
        cursor = inArea(cursor)
        setOrigin(keepZoom ? origin : area.origin)
        onChange?()
    }

    private func place(of p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) * k, y: (p.y - origin.y) * k) }

    func place() {
        let at = place(of: cursor)
        let size = cursorView.image?.size ?? .zero
        cursorView.frame = CGRect(x: at.x - hotspot.x, y: at.y - hotspot.y, width: size.width, height: size.height)
    }

    /// A screen's view, kept while the app shows another.
    struct State {
        var desk: CGSize, cursor: CGPoint, zoom: CGFloat, origin: CGPoint, box: CGRect
    }

    var state: State {
        get { State(desk: desk, cursor: cursor, zoom: zoom, origin: origin, box: box) }
        set {
            desk = newValue.desk
            box = newValue.box
            cursor = newValue.cursor
            zoom = newValue.zoom
            origin = newValue.origin
            apply()
            onChange?()
        }
    }

    /// A new desktop size (voxl's hello) or a new page: back to fit, the cursor kept in range.
    func reset(desk size: CGSize) {
        desk = size
        zoom = 1
        origin = area.origin
        cursor = inArea(cursor)
        apply()
        onChange?()
    }

    /// The Mac's pointer image (a data URL at the page's scale) and its hot spot, or none.
    func setImage(url: String?, hotspot h: CGPoint) {
        if let url, let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
           let image = UIImage(data: data, scale: UIScreen.main.scale) {
            cursorView.image = image
            hotspot = h
        } else if url == nil {
            cursorView.image = Pointer.arrow
            hotspot = CGPoint(x: 1, y: 1)
        }
        place()
    }

    var zoomText: String { zoom < 1.05 ? "Fit" : String(format: "%.1f×", zoom) }

    /// A plain arrow until the Mac's own pointer arrives.
    static let arrow: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 21)).image { _ in
        let p = UIBezierPath()
        p.move(to: CGPoint(x: 1, y: 1))
        p.addLine(to: CGPoint(x: 1, y: 17))
        p.addLine(to: CGPoint(x: 5, y: 13.5))
        p.addLine(to: CGPoint(x: 8, y: 20))
        p.addLine(to: CGPoint(x: 10.5, y: 19))
        p.addLine(to: CGPoint(x: 7.5, y: 12.5))
        p.addLine(to: CGPoint(x: 12.5, y: 12.5))
        p.close()
        UIColor.black.setFill()
        p.fill()
        UIColor.white.setStroke()
        p.lineWidth = 1.2
        p.stroke()
    }
}
