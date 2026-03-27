import AppKit
import XCTest

final class SmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchSmokeShowsMainControls() {
        let app = launchApp(scenario: "launchSmoke")

        XCTAssertTrue(element(in: app, identifier: "app.controlBar.toggle").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "app.pastMeetingsButton").waitForExistence(timeout: 5))
    }

    func testSettingsSmokeShowsCorePickers() {
        let app = launchApp(scenario: "launchSmoke")
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        // Settings window opens on General tab — verify the tab view exists
        let tabView = element(in: app, identifier: "settings.tabView")
        XCTAssertTrue(tabView.waitForExistence(timeout: 5))

        // Navigate to Intelligence tab and verify LLM picker
        app.toolbars.buttons["Intelligence"].click()
        XCTAssertTrue(element(in: app, identifier: "settings.llmProviderPicker").waitForExistence(timeout: 5))

        // Navigate to Transcription tab and verify model picker
        app.toolbars.buttons["Transcription"].click()
        XCTAssertTrue(element(in: app, identifier: "settings.transcriptionModelPicker").waitForExistence(timeout: 5))
    }

    func testSessionSmokeShowsEndedBanner() {
        let app = launchApp(scenario: "sessionSmoke")

        let toggle = element(in: app, identifier: "app.controlBar.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        toggle.click()
        XCTAssertTrue(waitForCondition(timeout: 5) {
            self.element(in: app, identifier: "app.controlBar.toggle").label.contains("Live")
        })

        toggle.click()
        XCTAssertTrue(element(in: app, identifier: "app.sessionEndedBanner").waitForExistence(timeout: 5))
    }

    func testNotesSmokeSupportsDeepLinkAndGeneration() {
        let app = launchApp(scenario: "notesSmoke")

        let deepLink = URL(string: "openoats://notes?sessionID=session_ui_test_notes")!
        openDeepLink(deepLink)

        XCTAssertTrue(element(in: app, identifier: "notes.generateButton").waitForExistence(timeout: 5))
        element(in: app, identifier: "notes.generateButton").click()
        XCTAssertTrue(element(in: app, identifier: "notes.renderedMarkdown").waitForExistence(timeout: 5))
    }

    private func launchApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OPENOATS_UI_TEST"] = "1"
        app.launchEnvironment["OPENOATS_UI_SCENARIO"] = scenario
        app.launchEnvironment["OPENOATS_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        return app
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openDeepLink(_ url: URL) {
        let hostAppURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenOatsUITestHost.app", isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: hostAppURL.path))

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        let opened = expectation(description: "open deep link in host app")
        var openError: Error?

        NSWorkspace.shared.open([url], withApplicationAt: hostAppURL, configuration: configuration) { _, error in
            openError = error
            opened.fulfill()
        }

        wait(for: [opened], timeout: 5)
        XCTAssertNil(openError)
    }

    private func waitForCondition(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
