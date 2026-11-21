import CoreAudio
@testable import OatsCapture
import Testing

private func bound(_ device: AudioDeviceID, _ rate: Double, _ channels: UInt32) -> MicCapture.Binding {
    MicCapture.Binding(device: device, rate: rate, channels: channels)
}

@Test func aNewHardwareFormatRebuildsTheMic() {
    // Bluetooth headset profile switch: AVFAudio rebinds the input to a 1 ch 44.1 kHz device under a 48 kHz tap.
    #expect(MicCapture.rebound(bound(125, 48_000, 2), now: bound(167, 44_100, 1)))
    #expect(MicCapture.rebound(bound(125, 48_000, 1), now: bound(125, 44_100, 1)))
    #expect(MicCapture.rebound(bound(125, 48_000, 2), now: bound(125, 48_000, 1)))
    // Engine 1 right after start: 3 ch 44.1 kHz → 3 ch 48 kHz.
    #expect(MicCapture.rebound(bound(101, 44_100, 3), now: bound(101, 48_000, 3)))
}

@Test func anotherDeviceRebuildsTheMicEvenAtTheSameFormat() {
    #expect(MicCapture.rebound(bound(125, 48_000, 1), now: bound(167, 48_000, 1)))
}

@Test func aFreshEngineIsNotRebound() {
    // The change a fresh engine posts just after starting reports the binding its tap was made at.
    #expect(!MicCapture.rebound(bound(125, 48_000, 1), now: bound(125, 48_000, 1)))
}

@Test func anUnknownDeviceOrUnusableFormatIsLeftToTheWatchdog() {
    let unknown = AudioDeviceID(kAudioObjectUnknown)
    #expect(!MicCapture.rebound(bound(125, 48_000, 1), now: bound(unknown, 0, 0)))
    #expect(!MicCapture.rebound(bound(125, 48_000, 1), now: bound(125, 0, 1)))
    #expect(!MicCapture.rebound(bound(125, 48_000, 1), now: bound(125, 44_100, 0)))
}

@Test func routeRebuildsAreDebouncedAndAtMostOneEvery2Seconds() {
    #expect(LiveCapture.routeRebuildDelay(sinceLast: .infinity) == 0.5)
    #expect(LiveCapture.routeRebuildDelay(sinceLast: 10) == 0.5)
    #expect(LiveCapture.routeRebuildDelay(sinceLast: 0.5) == 1.5)
    #expect(LiveCapture.routeRebuildDelay(sinceLast: 0) == 2)
}

@Test func aMicSilentSinceARouteChangeIsNotBlamed() {
    // Rebuilt 0.5 s after the change, silent ever since.
    #expect(!LiveCapture.blamesMic(silentFor: 4, sinceRouteChange: 4.5))
    #expect(!LiveCapture.blamesMic(silentFor: 5, sinceRouteChange: 6))
}

@Test func aMicThatDiesWithNoRouteChangeIsBlamed() {
    #expect(LiveCapture.blamesMic(silentFor: 4, sinceRouteChange: .infinity))
    // Worked for a while after the change, then went silent; or stayed silent through a second rebuild.
    #expect(LiveCapture.blamesMic(silentFor: 4, sinceRouteChange: 30))
    #expect(LiveCapture.blamesMic(silentFor: 4, sinceRouteChange: 8.5))
}
