@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Dispatch
import Foundation
import os

/// Captures system output audio via a Core Audio process tap.
final class SystemAudioCapture: @unchecked Sendable {
    private let _aggregateDeviceID = OSAllocatedUnfairLock<AudioObjectID>(
        uncheckedState: AudioObjectID(kAudioObjectUnknown)
    )
    private let _tapID = OSAllocatedUnfairLock<AudioObjectID>(
        uncheckedState: AudioObjectID(kAudioObjectUnknown)
    )
    private let _ioProcID = OSAllocatedUnfairLock<AudioDeviceIOProcID?>(uncheckedState: nil)
    private let _sysContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(
        uncheckedState: nil
    )
    private let callbackQueue = DispatchQueue(
        label: "com.openoats.system-audio",
        qos: .userInteractive
    )

    struct CaptureStreams {
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
    }

    func bufferStream(outputDeviceID: AudioDeviceID? = nil) async throws -> CaptureStreams {
        await stop()

        let sysStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self._sysContinuation.withLock { $0 = continuation }
        }

        let outputDeviceID = try (outputDeviceID ?? Self.defaultOutputDeviceID())
        let outputUID = try Self.deviceUID(for: outputDeviceID)
        let tapUUID = UUID()

        let tapDescription = CATapDescription()
        tapDescription.name = "OpenOats System Audio"
        tapDescription.uuid = tapUUID
        tapDescription.processes = Self.currentProcessObjectID().map { [$0] } ?? []
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        tapDescription.isMixdown = true
        tapDescription.isMono = true
        tapDescription.isExclusive = true
        tapDescription.deviceUID = outputUID
        tapDescription.stream = 0

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.tapCreationFailed(status)
        }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenOats System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard status == noErr else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }

        let streamDescription = try Self.tapStreamDescription(for: tapID)
        var mutableStreamDescription = streamDescription
        guard let format = AVAudioFormat(streamDescription: &mutableStreamDescription) else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.invalidTapFormat
        }

        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            callbackQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleInputData(inInputData, format: format)
        }
        guard status == noErr, let ioProcID else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.ioProcCreationFailed(status)
        }

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.startFailed(status)
        }

        let activeTapID = tapID
        let activeAggregateDeviceID = aggregateDeviceID
        let activeIOProcID = ioProcID

        _tapID.withLock { $0 = activeTapID }
        _aggregateDeviceID.withLock { $0 = activeAggregateDeviceID }
        _ioProcID.withLock { $0 = activeIOProcID }

        return CaptureStreams(systemAudio: sysStream)
    }

    /// Finish the async stream so consumers exit their for-await loop.
    /// Call this before stop() when you need a graceful drain.
    func finishStream() {
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
    }

    func stop() async {
        finishStream()

        let aggregateDeviceID = _aggregateDeviceID.withLock { state -> AudioObjectID in
            let current = state
            state = AudioObjectID(kAudioObjectUnknown)
            return current
        }
        let ioProcID = _ioProcID.withLock { state -> AudioDeviceIOProcID? in
            let current = state
            state = nil
            return current
        }
        let tapID = _tapID.withLock { state -> AudioObjectID in
            let current = state
            state = AudioObjectID(kAudioObjectUnknown)
            return current
        }

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
    }

    private func handleInputData(
        _ inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let streamDescription = format.streamDescription
        let bytesPerFrame = Int(streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, let firstBuffer = sourceBuffers.first else { return }

        let frameCount = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            return
        }
        pcmBuffer.frameLength = frameCount

        let destinationBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        guard destinationBuffers.count == sourceBuffers.count else { return }

        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            let copySize = min(
                Int(source.mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            guard copySize > 0,
                  let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData
            else {
                continue
            }

            memcpy(destinationData, sourceData, copySize)
            destinationBuffers[index].mDataByteSize = UInt32(copySize)
        }

        _ = _sysContinuation.withLock { $0?.yield(pcmBuffer) }
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    private static func currentProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = propertyAddress(selector: kAudioHardwarePropertyTranslatePIDToProcessObject)
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &dataSize,
                &processObjectID
            )
        }

        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return processObjectID
    }

    static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw CaptureError.noOutputDevice
        }
        return deviceID
    }

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var address = propertyAddress(selector: kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &uid
        )

        guard status == noErr, let uid else {
            throw CaptureError.outputDeviceUIDUnavailable(status)
        }
        return uid.takeRetainedValue() as String
    }

    private static func tapStreamDescription(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector: kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &dataSize,
            &streamDescription
        )

        guard status == noErr else {
            throw CaptureError.tapFormatUnavailable(status)
        }
        return streamDescription
    }

    enum CaptureError: LocalizedError {
        case noOutputDevice
        case outputDeviceUIDUnavailable(OSStatus)
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case invalidTapFormat
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noOutputDevice:
                return "No audio output device is currently available."
            case .outputDeviceUIDUnavailable(let status):
                return "Unable to inspect the system output device (OSStatus \(status))."
            case .tapCreationFailed(let status):
                return "System audio capture could not start. Enable System Audio Recording for OpenOats in System Settings > Privacy & Security (OSStatus \(status))."
            case .aggregateDeviceCreationFailed(let status):
                return "Unable to create the Core Audio aggregate device (OSStatus \(status))."
            case .tapFormatUnavailable(let status):
                return "Unable to inspect the system audio tap format (OSStatus \(status))."
            case .invalidTapFormat:
                return "System audio capture produced an unsupported audio format."
            case .ioProcCreationFailed(let status):
                return "Unable to create the system audio IO callback (OSStatus \(status))."
            case .startFailed(let status):
                return "Unable to start system audio capture (OSStatus \(status))."
            }
        }
    }
}
