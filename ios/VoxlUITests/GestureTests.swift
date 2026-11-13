import XCTest

/// Drives the app in the simulator against a dev voxl behind ios/devproxy.py on localhost:6918
/// (ios/build.sh uitest). What reached voxl is in
/// the test log (ios/testlog.py); the test performs the gestures, the log shows what they sent.
/// Points are fractions of the app's window on the folded screen (466 × 678 pt): the picture is the
/// band under the tabs, the pad is under it (its top holds the Trackpad | Direct switch). XCUITest
/// can't place element gestures on the Duo's outer screen (its two-finger tap lands on the screen's
/// edges), so the two-finger tap is left to the test on the phone.
final class GestureTests: XCTestCase {
    func testGesturesAndKeys() throws {
        let app = XCUIApplication()
        app.launch()
        addDevMachines(app)
        let cover = app.otherElements["cover"]
        XCTAssertTrue(app.otherElements["picture"].waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: cover)
        waitForExpectations(timeout: 40)
        let at = { (x: CGFloat, y: CGFloat) in app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)) }
        let picture = at(0.5, 0.33)

        picture.tap(); sleep(1)                                                  // click at the cursor
        at(0.3, 0.78).press(forDuration: 0.05, thenDragTo: at(0.7, 0.82)); sleep(1)   // the pad moves the cursor
        at(0.5, 0.80).press(forDuration: 0.6, thenDragTo: at(0.6, 0.83)); sleep(1)    // hold, then drag
        app.pinch(withScale: 3, velocity: 2); sleep(1)                           // zoom on the phone only
        app.buttons["Escape"].tap(); sleep(1)
        app.buttons["Command, for the next key"].tap()
        picture.tap(); sleep(1)                                                  // ⌘-click
        app.segmentedControls.buttons["Direct"].tap()
        at(0.25, 0.25).tap(); sleep(1)                                           // click where it touches
        at(0.5, 0.80).tap()                                                      // the pad still clicks at the cursor
        sleep(12)                                                                // the test log goes out every 10 s
    }

    /// The dev voxl's two "screens", added the way a person would: a voxlviewer://add link.
    func addDevMachines(_ app: XCUIApplication) {
        let machines = #"[{"name":"M1 dev","screens":[{"name":"plain","url":"http://localhost:6918/"},"#
            + #"{"name":"small","url":"http://localhost:6918/","sharp":"http://localhost:6918/?scale=0.5"}]}]"#
        let d = Data(machines.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        app.open(URL(string: "voxlviewer://add?d=\(d)")!)
        let add = app.alerts.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
    }

    /// Any device (SIM=...): the machines go in, the picture plays, and the screen is kept for a look.
    func testLayout() throws {
        let app = XCUIApplication()
        app.launch()
        addDevMachines(app)
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: app.otherElements["cover"])
        waitForExpectations(timeout: 40)
        sleep(3)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "layout"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
