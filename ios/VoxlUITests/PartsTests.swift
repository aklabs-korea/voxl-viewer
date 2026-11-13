import XCTest

/// Part of a screen, end to end: the screen's tab tapped again steps Left, Right, the window under the
/// Mac's pointer (fitted to the picture's room) and Whole (the window put back); the picture takes
/// each part's shape. (XCUITest's F1 doesn't reach the app.) Needs a voxl with the window routes on
/// localhost:6951 whose pointer is over a window the test may resize (PARTS_VOXL sets another address):
/// ONLY=PartsTests ios/build.sh uitest.
final class PartsTests: XCTestCase {
    let voxl = ProcessInfo.processInfo.environment["PARTS_VOXL"] ?? "http://localhost:6951"

    /// voxl's answer to a window route, as the app gets it.
    func ask(_ path: String) -> [String: Any] {
        var r = URLRequest(url: URL(string: voxl + path)!)
        r.setValue("1", forHTTPHeaderField: "X-Voxl-Window")
        var out: [String: Any] = [:]
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: r) { data, _, _ in
            out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return out
    }

    func testStepAndFit() throws {
        let app = XCUIApplication()
        app.launch()
        let machines = #"[{"name":"Parts","screens":[{"name":"test","url":"\#(voxl)/","sharp":"\#(voxl)/?scale=0.8"}]}]"#
        let d = Data(machines.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        app.open(URL(string: "voxlviewer://add?d=\(d)")!)
        let add = app.alerts.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        // Another machine on view (a simulator that ran GestureTests): pick this one.
        let machine = app.buttons["Parts"]
        if !machine.waitForExistence(timeout: 3), let current = app.buttons.allElementsBoundByIndex.first {
            current.tap()
            app.buttons["Parts"].tap()
        }
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: app.otherElements["cover"])
        waitForExpectations(timeout: 40)

        let picture = app.otherElements["picture"]
        let shape = { () -> CGFloat in let f = picture.frame; return f.height > 0 ? f.width / f.height : 0 }
        let whole = shape()
        let tab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '1 · test'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "a tab even for one screen")
        let step = {
            tab.tap()
            sleep(1)
        }
        let id = (ask("/window/at-pointer")["id"] as? NSNumber)?.uint64Value ?? 0
        let before = ask("/window/\(id)")

        step()
        XCTAssertEqual(shape(), whole / 2, accuracy: 0.05, "left half")
        step()
        XCTAssertEqual(shape(), whole / 2, accuracy: 0.05, "right half")
        step()
        sleep(2)
        let fitted = ask("/window/\(id)")
        XCTAssertEqual(fitted["fit"] as? String, "on", "fitted: \(fitted)")
        // Large: one Mac pixel per point of the picture's room, which is as wide as the app; the picture
        // then has the window's shape.
        let w = (fitted["w"] as? NSNumber)?.doubleValue ?? 0, h = (fitted["h"] as? NSNumber)?.doubleValue ?? 1
        XCTAssertEqual(w, app.windows.firstMatch.frame.width, accuracy: 40, "fitted to the app's width: \(fitted)")
        XCTAssertEqual(shape(), w / h, accuracy: 0.05, "the window's shape")

        step()
        XCTAssertEqual(shape(), whole, accuracy: 0.05, "whole again")
        let back = ask("/window/\(id)")
        XCTAssertNil(back["fit"], "put back: \(back)")
        for k in ["x", "y", "w", "h"] { XCTAssertEqual(back[k] as? NSNumber, before[k] as? NSNumber, k) }
    }
}
