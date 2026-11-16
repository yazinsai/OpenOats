import AppKit
import XCTest

/// UI smoke suite for 2.0: drives the packaged OpenOats.app (`OATS_APP`, set by scripts/run_ui_smoke.sh) with its
/// settings, Meetings and notes folder in throwaway places, a test tone for capture and the fake Transcription backend.
@MainActor
final class SmokeTests: XCTestCase {
    private var root: URL!
    private var app: XCUIApplication!

    private var appURL: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATS_APP"] ?? "") }
    private var meetings: URL { root.appendingPathComponent("Meetings") }
    private var notes: URL { root.appendingPathComponent("Notes") }
    /// The settings domain, as a plist path: the test runner is sandboxed, so it can't write a named suite the app reads.
    private var defaults: URL { root.appendingPathComponent("defaults.plist") }
    private var seeded: [String: Any] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(FileManager.default.fileExists(atPath: appURL.path), "OATS_APP is not a built OpenOats.app")
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenOatsUITests/\(id)")
        for dir in [meetings, notes] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // A cloud Transcription backend type, so onboarding doesn't download the on-device model; the fake replaces it.
        let settings = #"{"notesFolder":"\#(notes.absoluteString)","transcription":{"type":"openai-style"}}"#
        seeded = ["v2.settings": Data(settings.utf8)]
        try seed()
        app = XCUIApplication(url: appURL)
        app.launchEnvironment = [
            "OPENOATS_UI_TEST": "1", "OATS_DEFAULTS_SUITE": defaults.deletingPathExtension().path, "OATS_MEETINGS_DIR": meetings.path,
            "OATS_FAKE_CAPTURE": "1", "OATS_FAKE_TRANSCRIPTION": "0",
        ]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func seed() throws {
        try PropertyListSerialization.data(fromPropertyList: seeded, format: .binary, options: 0).write(to: defaults)
    }

    private func onboarded() throws {
        seeded["v2.consentAcknowledged"] = Date()
        try seed()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func text(containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", value, value)).firstMatch
    }

    /// Opens the menu bar panel; skips when the status item is hidden (a crowded menu bar or a menu bar manager).
    private func openMenuBarPanel() throws {
        let item = app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        try XCTSkipUnless(item.isHittable, "the OpenOats status item is hidden in this menu bar")
        item.click()
    }

    private func menuRow(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Launching the running app again shows the window, as from Finder or Spotlight.
    private func reopen() {
        let done = expectation(description: "reopen")
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func open(_ url: String) {
        let done = expectation(description: url)
        NSWorkspace.shared.open([URL(string: url)!], withApplicationAt: appURL, configuration: .init()) { _, _ in done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func testOnboardingNeedsConsentAndShowsOnce() {
        app.launch()
        XCTAssertTrue(element("onboarding.root").waitForExistence(timeout: 10))
        let done = app.buttons["Done"]
        XCTAssertFalse(done.isEnabled)
        element("onboarding.consent").click()
        XCTAssertTrue(done.isEnabled)
        done.click()
        XCTAssertTrue(element("onboarding.root").waitForNonExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(element("onboarding.root").waitForExistence(timeout: 3))
    }

    func testMeetingListShowsASeededMeetingAndItsMeetingFile() throws {
        try onboarded()
        let folder = meetings.appendingPathComponent("2026-11-16-100000-ab12")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = notes.appendingPathComponent("2026-11-16-1000-budget-review.md")
        try """
        ---
        schema: openoats/v1
        title: "Budget review"
        date: 2026-11-16T10:00:00Z
        duration: 12
        participants:
          - You
          - Them
        x_openoats_meeting: "2026-11-16-100000-ab12"
        ---

        # Budget review

        - Ship the smoke suite

        ## Transcript

        [00:00:01] **You:** Let's look at the numbers.

        """.write(to: file, atomically: true, encoding: .utf8)
        try #"{"state":"done","startedAt":"2026-11-16T10:00:00Z","interrupted":false,"duration":900,"completedSteps":["transcribe","merge","notes"],"meetingFile":"\#(file.path)"}"#
            .write(to: folder.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)

        let failed = meetings.appendingPathComponent("2026-11-15-090000-cd34")
        try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        try #"{"state":"needs-attention","startedAt":"2026-11-15T09:00:00Z","interrupted":false,"completedSteps":[],"lastError":"The Transcription backend is unreachable."}"#
            .write(to: failed.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)

        app.launch()
        reopen()
        XCTAssertTrue(element("meetings.list").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Budget review").waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "15 min").exists) // meeting.json says 15, the Meeting file 12: the Meeting folder was read
        XCTAssertTrue(text(containing: "Needs attention").exists)
        XCTAssertTrue(text(containing: "Let's look at the numbers.").waitForExistence(timeout: 5))
    }

    func testStartAndStopByURLWritesAMeetingFile() throws {
        try onboarded()
        app.launch()
        reopen()
        XCTAssertTrue(element("meetings.list").waitForExistence(timeout: 10))
        open("openoats://start")
        XCTAssertTrue(text(containing: "Recording").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        open("openoats://stop")
        XCTAssertTrue(text(containing: "Mic track lasted").waitForExistence(timeout: 30))
        let files = try FileManager.default.contentsOfDirectory(atPath: notes.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(files.count, 1)
        let content = try String(contentsOf: notes.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(content.contains("**You:** Mic track lasted "))
        XCTAssertTrue(content.contains("**Them:** System audio, "))
    }

    func testStartAndStopFromTheMenuBar() throws {
        try onboarded()
        app.launch()
        try openMenuBarPanel()
        menuRow("Start Recording").click()
        try openMenuBarPanel()
        XCTAssertTrue(menuRow("Stop Recording").waitForExistence(timeout: 5))
        menuRow("Stop Recording").click()
        try openMenuBarPanel()
        XCTAssertTrue(menuRow("Start Recording").waitForExistence(timeout: 5))
    }

    func testSettingsOpenWithBackendPickers() throws {
        try onboarded()
        app.launch()
        reopen()
        XCTAssertTrue(element("meetings.list").waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("settings.tabView").waitForExistence(timeout: 10))
        app.toolbars.buttons["AI"].click()
        XCTAssertTrue(element("settings.notesBackend").waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.transcriptionBackend").exists)
    }
}
