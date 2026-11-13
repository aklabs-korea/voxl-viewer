import XCTest

/// The state-machine audit's findings (ios/model), replayed on the real app against the dev voxl, through
/// ios/devproxy.py's control port (localhost:6917) to make voxl slow, wide, silent or gone. Each test fails
/// on the code the model found the bug in. Run with ios/build.sh uitest (ONLY=ReproTests/...).
final class ReproTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        proxy("reset")
        app = XCUIApplication()
        // Each test starts on screen 1, whatever the last one ended on.
        app.launchArguments = ["-lastMachine", "M1 dev", "-lastRow", "0"]
        app.launch()
    }

    override func tearDown() { proxy("reset") }

    /// One command to the dev proxy.
    @discardableResult
    func proxy(_ command: String) -> String {
        var out = ""
        let done = expectation(description: command)
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:6917/\(command)")!) { d, _, _ in
            out = String(decoding: d ?? Data(), as: UTF8.self)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return out
    }

    func addDevMachines() {
        let machines = #"[{"name":"M1 dev","screens":[{"name":"plain","url":"http://localhost:6918/"},"#
            + #"{"name":"small","url":"http://localhost:6918/","sharp":"http://localhost:6918/?scale=0.5"}]}]"#
        let d = Data(machines.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        app.open(URL(string: "voxlviewer://add?d=\(d)")!)
        let add = app.alerts.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
    }

    var cover: XCUIElement { app.otherElements["cover"] }

    func waitForPicture(_ timeout: TimeInterval = 40) {
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: cover)
        waitForExpectations(timeout: timeout)
    }

    func coverSays(_ text: String) -> XCUIElement {
        cover.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 2: voxl answers late; once it has, the cover no longer says it isn't answering.
    func testCoverStopsSayingNotAnsweringOnceItAnswers() {
        proxy("delay?s=5")
        addDevMachines()
        XCTAssertTrue(coverSays("isn't answering").waitForExistence(timeout: 6))
        proxy("delay?s=0")
        // The answer comes 5 s after the try; the cover must change at the latest when the page commits.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: coverSays("isn't answering"))
        waitForExpectations(timeout: 12)
    }

    /// 3: late, then wider than the phone plays: "Ask for Sharp" asks for Sharp on this screen.
    func testAskForSharpStaysOnThisScreen() {
        proxy("delay?s=5")
        proxy("wide/on")
        addDevMachines()
        // Slow first (the cover says it isn't answering, and offers the other screen), then wide.
        XCTAssertTrue(coverSays("isn't answering").waitForExistence(timeout: 6))
        proxy("delay?s=0")
        let sharp = cover.buttons["Ask for Sharp"]
        XCTAssertTrue(sharp.waitForExistence(timeout: 40))
        proxy("wide/off")
        sharp.tap()
        XCTAssertTrue(app.buttons["1 · plain"].waitForExistence(timeout: 5))
        waitForPicture()
        sleep(11)   // the test log goes out every 10 s
        XCTAssertTrue(app.buttons["1 · plain"].isSelected || app.buttons["1 · plain"].value as? String == "on",
                      "the app left screen 1")
    }

    /// 4: another viewer takes Full while the picture plays, then leaves: the cover goes again.
    func testFullCoverGoesWhenTheScreenIsSharpAgain() {
        addDevMachines()
        waitForPicture()
        proxy("wide/on")
        proxy("drop")
        XCTAssertTrue(cover.buttons["Ask for Sharp"].waitForExistence(timeout: 15))
        proxy("wide/off")
        proxy("drop")
        waitForPicture(20)
    }

    /// 5: the socket goes silent without closing: the app gets a fresh page by itself (the cover shows while
    /// it connects), and that page plays.
    func testSilentSocketGetsAFreshPage() {
        addDevMachines()
        waitForPicture()
        proxy("silence")
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: cover)
        waitForExpectations(timeout: 25)
        waitForPicture(30)
    }

    /// 9: an armed ⌘ isn't shown lit once the page that had it is gone.
    func testBarModifierNotLitAfterReload() {
        addDevMachines()
        waitForPicture()
        let cmd = app.buttons["Command, for the next key"]
        cmd.tap()
        XCTAssertEqual(cmd.value as? String, "on")
        app.buttons["More"].tap()
        app.buttons["Reconnect"].tap()
        waitForPicture()
        XCTAssertEqual(cmd.value as? String, "off", "the bar shows a ⌘ the page doesn't have")
    }

    /// 1 and 7 leave what they need in the test log (the page's audio session, the release on reconnect):
    /// switch screens, then drop the socket.
    func testSwitchThenDrop() {
        addDevMachines()
        waitForPicture()
        app.buttons["2 · small"].tap()
        waitForPicture()
        proxy("drop")
        sleep(6)
        sleep(10)   // the test log goes out every 10 s
    }
}
