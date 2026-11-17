import Foundation
import OatsCore
import Testing

/// Which audio activity counts as a Call, and when it starts and ends.
@Suite struct CallDetectorTests {
    var detector = CallDetector()
    let t0 = Date(timeIntervalSince1970: 0)

    /// Feeds the same clients every 2 s from `from` to `to` seconds; returns the events with their times.
    mutating func run(_ clients: [AudioClient], camera: Bool = false, from: Int, to: Int) -> [(Int, CallEvent)] {
        stride(from: from, through: to, by: 2).flatMap { s in
            detector.update(clients, cameraOn: camera, at: t0 + Double(s)).map { (s, $0) }
        }
    }

    static func client(_ id: String, input: Bool = true, output: Bool = true) -> AudioClient {
        AudioClient(bundleID: id, input: input, output: output)
    }

    let zoom = CallApp.named("us.zoom.xos")!

    @Test mutating func twoWayAudioForFiveSecondsIsACall() {
        let events = run([Self.client("us.zoom.xos")], from: 0, to: 10)
        #expect(events.map(\.0) == [6])
        #expect(events.map(\.1) == [.started(zoom)])
    }

    @Test mutating func micAloneIsNotACall() {
        // A WhatsApp voice note: the mic, but nothing played.
        #expect(run([Self.client("net.whatsapp.WhatsApp", output: false)], from: 0, to: 60).isEmpty)
        #expect(!detector.isTracking)
    }

    @Test mutating func dictationNextToAMeetingAppIsNotACall() {
        // 1.x #726: Superwhisper holds the mic while WhatsApp plays a sound; neither app has two-way audio.
        let clients = [Self.client("com.superduper.superwhisper"), Self.client("net.whatsapp.WhatsApp", input: false)]
        #expect(run(clients, from: 0, to: 60).isEmpty)
    }

    @Test mutating func theAppDoingTheAudioIsNamedNotAnotherOneThatIsOpen() {
        // 1.x #643: Teams sits open while the Call is a Meet tab in Brave.
        let clients = [Self.client("com.microsoft.teams2", input: false, output: false), Self.client("com.brave.Browser.helper")]
        #expect(run(clients, from: 0, to: 10).map(\.1) == [.started(CallApp.named("com.brave.Browser")!)])
    }

    @Test func helpersAndCaseCountAsTheirApp() {
        #expect(CallApp.of("com.google.Chrome.helper")?.name == "Google Chrome")
        #expect(CallApp.of("com.apple.WebKit.GPU")?.name == "Safari")
        #expect(CallApp.of("US.ZOOM.XOS")?.name == "Zoom")
        #expect(CallApp.of("com.microsoft.teams2")?.name == "Microsoft Teams")
        #expect(CallApp.of("com.google.Chromecast") == nil)
        #expect(CallApp.of("com.openoats.app") == nil)
    }

    @Test mutating func shortTwoWayBlipsAreNotACall() {
        // A notification sound while dictating into Chrome: two-way for one sample, then mic only.
        _ = run([Self.client("com.google.Chrome.helper")], from: 0, to: 2)
        #expect(run([Self.client("com.google.Chrome.helper", output: false)], from: 4, to: 30).isEmpty)
    }

    @Test mutating func aCallEndsTwentySecondsAfterTheMicIsReleased() {
        _ = run([Self.client("us.zoom.xos")], from: 0, to: 30)
        #expect(run([], from: 32, to: 48).isEmpty)
        #expect(run([], from: 50, to: 54).map(\.0) == [50])
        #expect(!detector.isTracking)
    }

    @Test mutating func aBriefMicDropKeepsOneCall() {
        // Switching headsets mid-call releases the mic for a few seconds.
        _ = run([Self.client("us.zoom.xos")], from: 0, to: 30)
        _ = run([], from: 32, to: 40)
        #expect(run([Self.client("us.zoom.xos")], from: 42, to: 120).isEmpty)
        #expect(detector.current == [zoom])
    }

    @Test mutating func mutedSpeakersDoNotEndACall() {
        // Once a Call is on, holding the mic is enough to keep it.
        _ = run([Self.client("us.zoom.xos")], from: 0, to: 10)
        #expect(run([Self.client("us.zoom.xos", output: false)], from: 12, to: 120).isEmpty)
    }

    @Test mutating func twoAppsAreTwoCalls() {
        let events = run([Self.client("us.zoom.xos"), Self.client("com.apple.avconferenced")], from: 0, to: 6)
        #expect(events.map(\.1) == [.started(CallApp.named("com.apple.FaceTime")!), .started(zoom)])
    }

    @Test mutating func aCameraBacksUpACallAppOnTheMic() {
        // Speaker output routed through another process (or a muted call): the camera stands in for it.
        let events = run([Self.client("com.google.Chrome.helper", output: false)], camera: true, from: 0, to: 10)
        #expect(events.map(\.1) == [.started(CallApp.named("com.google.Chrome")!)])
    }

    @Test mutating func aCameraAloneIsNotACall() {
        // 1.x #643/#657: Photo Booth or a camera check prompted, naming whatever meeting app was open.
        #expect(run([Self.client("com.microsoft.teams2", input: false, output: false)], camera: true, from: 0, to: 60).isEmpty)
    }

    @Test mutating func aCameraDoesNotMakeDictationACall() {
        let clients = [Self.client("com.superduper.superwhisper"), Self.client("net.whatsapp.WhatsApp", input: false)]
        #expect(run(clients, camera: true, from: 0, to: 60).isEmpty)
    }
}
