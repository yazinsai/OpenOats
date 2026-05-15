import Foundation
import XCTest
@testable import OpenOatsKit

@MainActor
final class WhatsNewControllerTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.openoats.tests.whatsnew.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeRelease(version: String = "1.78.0") -> WhatsNewRelease {
        WhatsNewRelease(
            version: version,
            title: "OpenOats \(version)",
            body: "## Fixed\n- Notes render correctly.",
            htmlURL: URL(string: "https://github.com/yazinsai/OpenOats/releases/tag/v\(version)")!
        )
    }

    func testShouldShowOnlyForNewerSemanticVersion() {
        XCTAssertTrue(WhatsNewController.shouldShow(currentVersion: "1.78.0", lastSeenVersion: "1.77.0"))
        XCTAssertTrue(WhatsNewController.shouldShow(currentVersion: "1.78.1", lastSeenVersion: "1.78.0"))
        XCTAssertFalse(WhatsNewController.shouldShow(currentVersion: "1.77.0", lastSeenVersion: "1.77.0"))
        XCTAssertFalse(WhatsNewController.shouldShow(currentVersion: "1.76.9", lastSeenVersion: "1.77.0"))
    }

    func testShouldShowFailsClosedForMalformedVersions() {
        XCTAssertFalse(WhatsNewController.shouldShow(currentVersion: "1.78", lastSeenVersion: "1.77.0"))
        XCTAssertFalse(WhatsNewController.shouldShow(currentVersion: "1.78.0-beta", lastSeenVersion: "1.77.0"))
        XCTAssertFalse(WhatsNewController.shouldShow(currentVersion: "1.78.0", lastSeenVersion: "latest"))
    }

    func testFirstInstallStoresCurrentVersionWithoutShowingRelease() async {
        let defaults = makeDefaults()
        var fetchCount = 0
        let controller = WhatsNewController(
            defaults: defaults,
            currentVersionProvider: { "1.78.0" },
            fetchRelease: { version in
                fetchCount += 1
                return self.makeRelease(version: version)
            }
        )

        await controller.presentPostUpdateReleaseNotesIfNeeded()

        XCTAssertNil(controller.presentedRelease)
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(defaults.string(forKey: WhatsNewController.lastSeenVersionKey), "1.78.0")
    }

    func testUpdateFetchesReleaseAndMarksSeenOnDismiss() async {
        let defaults = makeDefaults()
        defaults.set("1.77.0", forKey: WhatsNewController.lastSeenVersionKey)
        let controller = WhatsNewController(
            defaults: defaults,
            currentVersionProvider: { "1.78.0" },
            fetchRelease: { version in self.makeRelease(version: version) }
        )

        await controller.presentPostUpdateReleaseNotesIfNeeded()

        XCTAssertEqual(controller.presentedRelease?.version, "1.78.0")
        XCTAssertEqual(defaults.string(forKey: WhatsNewController.lastSeenVersionKey), "1.77.0")

        controller.markPresentedReleaseSeen()

        XCTAssertNil(controller.presentedRelease)
        XCTAssertEqual(defaults.string(forKey: WhatsNewController.lastSeenVersionKey), "1.78.0")
    }

    func testFailedFetchDoesNotMarkVersionSeen() async {
        struct TestError: Error {}

        let defaults = makeDefaults()
        defaults.set("1.77.0", forKey: WhatsNewController.lastSeenVersionKey)
        let controller = WhatsNewController(
            defaults: defaults,
            currentVersionProvider: { "1.78.0" },
            fetchRelease: { _ in throw TestError() }
        )

        await controller.presentPostUpdateReleaseNotesIfNeeded()

        XCTAssertNil(controller.presentedRelease)
        XCTAssertEqual(defaults.string(forKey: WhatsNewController.lastSeenVersionKey), "1.77.0")
    }

    func testCheckRunsOnlyOncePerLaunch() async {
        let defaults = makeDefaults()
        defaults.set("1.77.0", forKey: WhatsNewController.lastSeenVersionKey)
        var fetchCount = 0
        let controller = WhatsNewController(
            defaults: defaults,
            currentVersionProvider: { "1.78.0" },
            fetchRelease: { version in
                fetchCount += 1
                return self.makeRelease(version: version)
            }
        )

        await controller.presentPostUpdateReleaseNotesIfNeeded()
        await controller.presentPostUpdateReleaseNotesIfNeeded()

        XCTAssertEqual(fetchCount, 1)
    }
}
