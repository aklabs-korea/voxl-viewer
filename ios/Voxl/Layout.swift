import CoreGraphics
import UIKit

/// Where the screen tabs, the picture, the pad and the key bar go: one function of the window's
/// size, its safe area, the iPhone keyboard and the fold, so every pose (closed, open flat,
/// half-open like a laptop or a book) and every rotation runs the same code.
struct Frames: Equatable {
    var nav: CGRect
    var picture: CGRect
    /// The room the picture is fitted into: the shape a Mac window is fitted to (Parts.swift).
    var room: CGRect
    var pad: CGRect
    var keys: CGRect
}

enum Layout {
    static let navHeight: CGFloat = 44
    static let keysHeight: CGFloat = 52
    /// Without a fold and with the keyboard down, the pad keeps at least this much under the picture.
    static let minPad: CGFloat = 110

    /// fold: the active division region (the hinge, half-open), in the same coordinates.
    /// keyboardTop: where the iPhone keyboard starts (nil: it's down). aspect: the desktop's width over its height.
    static func frames(size: CGSize, safe: UIEdgeInsets, fold: CGRect?, keyboardTop: CGFloat?, aspect: CGFloat) -> Frames {
        var area = CGRect(origin: .zero, size: size).inset(by: safe)
        if let top = keyboardTop, top < area.maxY { area.size.height = max(0, top - area.minY) }
        if let fold, fold.width >= fold.height, fold.minY > area.minY {
            // Like a laptop: the picture above the fold; tabs, pad and keys below it, on the base.
            let top = CGRect(x: area.minX, y: area.minY, width: area.width, height: fold.minY - area.minY)
            let base = CGRect(x: area.minX, y: fold.maxY, width: area.width, height: max(0, area.maxY - fold.maxY))
            let (nav, pad, keys) = column(base)
            return Frames(nav: nav, picture: fit(aspect, in: top), room: top, pad: pad, keys: keys)
        }
        if let fold, fold.height > fold.width, fold.minX > area.minX {
            // Like a book: the picture on the left half; tabs, pad and keys on the right.
            let left = CGRect(x: area.minX, y: area.minY, width: fold.minX - area.minX, height: area.height)
            let right = CGRect(x: fold.maxX, y: area.minY, width: max(0, area.maxX - fold.maxX), height: area.height)
            let (nav, pad, keys) = column(right)
            return Frames(nav: nav, picture: fit(aspect, in: left), room: left, pad: pad, keys: keys)
        }
        // Flat or closed: tabs on top, the picture across the whole width, the pad, the keys at the bottom.
        let (nav, below) = area.divided(atDistance: min(navHeight, area.height), from: .minYEdge)
        let (keys, middle) = below.divided(atDistance: min(keysHeight, below.height), from: .maxYEdge)
        let room = keyboardTop == nil ? middle.height - minPad : middle.height
        let height = max(0, min(middle.width / aspect, room))
        let (row, pad) = middle.divided(atDistance: height, from: .minYEdge)
        let most = CGRect(x: middle.minX, y: middle.minY, width: middle.width, height: max(0, room))
        return Frames(nav: nav, picture: fit(aspect, in: row), room: most, pad: pad, keys: keys)
    }

    /// Tabs on top, keys at the bottom, the pad between.
    private static func column(_ r: CGRect) -> (CGRect, CGRect, CGRect) {
        let (nav, rest) = r.divided(atDistance: min(navHeight, r.height), from: .minYEdge)
        let (keys, pad) = rest.divided(atDistance: min(keysHeight, rest.height), from: .maxYEdge)
        return (nav, pad, keys)
    }

    /// The biggest rect of that aspect inside box, centered, on whole points.
    static func fit(_ aspect: CGFloat, in box: CGRect) -> CGRect {
        guard box.width > 0, box.height > 0, aspect > 0 else { return CGRect(x: box.midX, y: box.midY, width: 0, height: 0) }
        var w = box.width, h = w / aspect
        if h > box.height { h = box.height; w = h * aspect }
        return CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(),
                      width: w.rounded(), height: h.rounded())
    }
}
