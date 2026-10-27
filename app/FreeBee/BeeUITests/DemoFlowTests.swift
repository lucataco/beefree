import XCTest

/// Drives the app against its simulated Bee (`-demo YES`), so it runs in the simulator with no hardware.
final class DemoFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
    }

    func testHomeShowsOneStatus() {
        // The demo Bee is recording, and its audio verifies once the session is open.
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 20))
        XCTAssertTrue(element(containing: "Saving to this iPhone").exists)
        XCTAssertTrue(app.buttons["Mute"].exists)
        snapshot("1-home")
        openYourBee()
        XCTAssertTrue(app.staticTexts["Battery"].waitForExistence(timeout: 5))
        snapshot("2-your-bee")
    }

    func testMuteAndUnmute() {
        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 10))
        mute.tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Muted"].exists)
        snapshot("3-muted")
        app.buttons["Unmute"].tap()
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 5))
    }

    func testEventsAreLogged() {
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 10))
        app.buttons["Mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 5))
        openYourBee()
        let doublePress = app.buttons["Double-press the button"]
        scroll(to: doublePress)
        doublePress.tap()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Event Log"].tap()
        XCTAssertTrue(element(containing: "Double press").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Muted · Microphone off · in the app").exists)
        XCTAssertTrue(element(containing: "Connected").exists)
        snapshot("4-event-log")
    }

    func testFirmwareScreen() {
        openYourBee()
        let firmware = app.buttons.containing(.staticText, identifier: "Firmware").firstMatch
        scroll(to: firmware)
        XCTAssertTrue(firmware.waitForExistence(timeout: 5))
        firmware.tap()
        XCTAssertTrue(app.staticTexts["MCUboot"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["0.5.0"].exists)
    }

    func testSettingsAndKey() {
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Leave Demo"].waitForExistence(timeout: 5))
        snapshot("5-settings")
        app.buttons.containing(.staticText, identifier: "Audio Key").firstMatch.tap()
        XCTAssertTrue(app.buttons["Import secrets.json…"].waitForExistence(timeout: 5))
    }

    func testSleepAndPowerOff() {
        openYourBee()
        let sleep = app.buttons["Sleep"]
        XCTAssertTrue(sleep.waitForExistence(timeout: 10))
        sleep.tap()
        app.buttons["Software voice detection"].tap()
        XCTAssertTrue(element(containing: "Asleep").waitForExistence(timeout: 5))

        app.buttons["Turn Off"].tap()
        let confirm = app.buttons["Turn Off Bee"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Off"].waitForExistence(timeout: 5))
        snapshot("6-off")
        // The demo Bee comes back by itself, muted.
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Muted"].exists)
    }

    func testCaptureVerifiesInDemo() {
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 20))
        openYourBee()
        let link = element(containing: "MTU 498")
        scroll(to: link)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        snapshot("7-audio-link")
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Event Log"].tap()
        XCTAssertTrue(element(containing: "Audio verified").waitForExistence(timeout: 5))
    }

    func testConversationsAndTodos() {
        XCTAssertTrue(app.tabBars.buttons["Conversations"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Conversations"].tap()
        XCTAssertTrue(app.buttons["Process Now"].waitForExistence(timeout: 5))
        snapshot("8-conversations")
        app.tabBars.buttons["To-dos"].tap()
        XCTAssertTrue(app.staticTexts["Nothing to Do"].waitForExistence(timeout: 5))
        snapshot("9-todos")
    }

    func testProcessingSettings() {
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        app.buttons.containing(.staticText, identifier: "Transcription").firstMatch.tap()
        XCTAssertTrue(element(containing: "Ends after 2 min of silence").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Apple Intelligence"].exists || element(containing: "Apple Intelligence").exists)
    }

    private func openYourBee() {
        let row = app.buttons.containing(.staticText, identifier: "Your Bee").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    /// Scrolls down until `element` is on screen (lists only build the rows they show).
    private func scroll(to element: XCUIElement, attempts: Int = 8) {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return }
            scrollDown()
        }
    }

    /// Drags along the left margin, clear of the brightness slider.
    private func scrollDown() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.3)))
    }

    /// Rows that combine their children expose one merged label, so match on part of it.
    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
