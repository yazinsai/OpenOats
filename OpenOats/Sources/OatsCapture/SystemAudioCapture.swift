@preconcurrency import AVFoundation
import CoreAudio
import OatsCore

/// The System track: a Core Audio process tap on the default output device (everything but our own process), read
/// through a private aggregate device. macOS 14.2+. Used on the LiveCapture queue only.
final class SystemAudioCapture {
    private let ioQueue = DispatchQueue(label: "openoats.capture.system", qos: .userInteractive)
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    let activity = Activity()

    /// Builds a fresh tap on the current default output device, replacing any running one.
    func start(_ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws {
        activity.touch(delivered: false)
        var lastError = CaptureError.tapFormatUnavailable(kAudioHardwareBadObjectError)
        for attempt in 0..<3 {
            stop()
            if attempt > 0 { usleep(200_000) }
            do {
                return try attemptStart(deliver)
            } catch let error as CaptureError where error.isTransient {
                lastError = error
            } catch {
                stop()
                throw error
            }
        }
        stop()
        throw lastError
    }

    private func attemptStart(_ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws {
        guard let output = AudioDevices.defaultOutput, let outputUID = AudioDevices.uid(output) else { throw CaptureError.noOutputDevice }
        let tapUUID = UUID()
        var status = AudioHardwareCreateProcessTap(
            Self.makeTapDescription(outputUID: outputUID, excludingProcess: AudioDevices.currentProcessObject(), uuid: tapUUID), &tap)
        // Not noErr is almost always a missing permission.
        guard status == noErr else { throw CaptureError.tapCreationFailed(status) }
        guard tap != kAudioObjectUnknown else { throw CaptureError.tapCreationFailed(kAudioHardwareBadObjectError) }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenOats System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw CaptureError.aggregateDeviceCreationFailed(status) }

        // USB/Bluetooth devices can take up to ~3 s before the tap's format resolves.
        var asbd = AudioStreamBasicDescription()
        for _ in 0..<40 {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
            if status != kAudioHardwareBadObjectError { break }
            usleep(75_000)
        }
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.tapFormatUnavailable(status) }

        let resampler = Resampler(.system, deliver)
        let activity = activity
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, ioQueue) { _, input, inputTime, _, _ in
            // Fires only while the output device runs (macOS 26: no callbacks while nothing plays).
            activity.touch()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            let time = inputTime.pointee
            resampler.convert(buffer, hostTime: time.mFlags.contains(.hostTimeValid) ? time.mHostTime : 0)
        }
        guard status == noErr, let ioProc else { throw CaptureError.ioProcCreationFailed(status) }
        status = AudioDeviceStart(aggregate, ioProc)
        guard status == noErr else { throw CaptureError.startFailed(status) }
    }

    /// Sonoma fix (#721): a device-bound tap needs `stream = 0`, else the HAL logs "Stream out of range for tap" and
    /// returns noErr with tap ID 0.
    static func makeTapDescription(outputUID: String, excludingProcess process: AudioObjectID?, uuid: UUID) -> CATapDescription {
        let d = CATapDescription()
        d.name = "OpenOats System Audio"
        d.uuid = uuid
        d.processes = process.map { [$0] } ?? [] // exclusive: every process except these
        d.isPrivate = true
        d.muteBehavior = .unmuted
        d.isMixdown = true
        d.isMono = true
        d.isExclusive = true
        d.deviceUID = outputUID
        d.stream = 0
        return d
    }

    /// Tears everything down; on every path, or private aggregate devices leak until coreaudiod restarts.
    func stop() {
        if aggregate != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregate, ioProc)
                AudioDeviceDestroyIOProcID(aggregate, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        ioProc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}
