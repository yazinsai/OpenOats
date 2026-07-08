@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Dispatch
import Foundation
import os

/// Captures system output audio via a Core Audio process tap.
final class SystemAudioCapture: @unchecked Sendable {
    struct SystemAudioDiagnosticsEvent: Codable, Equatable {
        let event: String
        let attempt: Int?
        let requestedOutputDeviceID: UInt32?
        let resolvedOutputDeviceID: UInt32?
        let outputDeviceAvailable: Bool?
        let outputDeviceUIDLength: Int?
        let availableOutputDeviceCount: Int?
        let outputStreamCount: Int?
        let outputNominalSampleRate: Double?
        let outputTransportType: UInt32?
        let processObjectID: UInt32?
        let processCount: Int?
        let tapID: UInt32?
        let aggregateDeviceID: UInt32?
        let ioProcCreated: Bool?
        let status: Int32?
        let cleanupAggregateStatus: Int32?
        let cleanupTapStatus: Int32?
        let retryIndex: Int?
        let retryCount: Int?
        let sampleRate: Double?
        let channels: UInt32?
        let bytesPerFrame: UInt32?
        let flags: [String: Bool]?
        let errorKind: String?

        init(
            event: String,
            attempt: Int? = nil,
            requestedOutputDeviceID: UInt32? = nil,
            resolvedOutputDeviceID: UInt32? = nil,
            outputDeviceAvailable: Bool? = nil,
            outputDeviceUIDLength: Int? = nil,
            availableOutputDeviceCount: Int? = nil,
            outputStreamCount: Int? = nil,
            outputNominalSampleRate: Double? = nil,
            outputTransportType: UInt32? = nil,
            processObjectID: UInt32? = nil,
            processCount: Int? = nil,
            tapID: UInt32? = nil,
            aggregateDeviceID: UInt32? = nil,
            ioProcCreated: Bool? = nil,
            status: Int32? = nil,
            cleanupAggregateStatus: Int32? = nil,
            cleanupTapStatus: Int32? = nil,
            retryIndex: Int? = nil,
            retryCount: Int? = nil,
            sampleRate: Double? = nil,
            channels: UInt32? = nil,
            bytesPerFrame: UInt32? = nil,
            flags: [String: Bool]? = nil,
            errorKind: String? = nil
        ) {
            self.event = event
            self.attempt = attempt
            self.requestedOutputDeviceID = requestedOutputDeviceID
            self.resolvedOutputDeviceID = resolvedOutputDeviceID
            self.outputDeviceAvailable = outputDeviceAvailable
            self.outputDeviceUIDLength = outputDeviceUIDLength
            self.availableOutputDeviceCount = availableOutputDeviceCount
            self.outputStreamCount = outputStreamCount
            self.outputNominalSampleRate = outputNominalSampleRate
            self.outputTransportType = outputTransportType
            self.processObjectID = processObjectID
            self.processCount = processCount
            self.tapID = tapID
            self.aggregateDeviceID = aggregateDeviceID
            self.ioProcCreated = ioProcCreated
            self.status = status
            self.cleanupAggregateStatus = cleanupAggregateStatus
            self.cleanupTapStatus = cleanupTapStatus
            self.retryIndex = retryIndex
            self.retryCount = retryCount
            self.sampleRate = sampleRate
            self.channels = channels
            self.bytesPerFrame = bytesPerFrame
            self.flags = flags
            self.errorKind = errorKind
        }
    }

    private let _audioLevel = AudioLevel()
    private let _hasCapturedFrames = SyncBool()
    private let _paused = SyncBool()

    /// Thread-safe audio level (0…1) from the system audio stream.
    var audioLevel: Float { _paused.value ? 0 : _audioLevel.value }
    var hasCapturedFrames: Bool { _hasCapturedFrames.value }

    /// When paused, buffers are not forwarded to the stream and audio level reads as 0.
    var isPaused: Bool {
        get { _paused.value }
        set { _paused.value = newValue }
    }

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

    static func systemAudioDiagnosticsMessage(for event: SystemAudioDiagnosticsEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(event),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return #"{"event":"system_audio_capture_diagnostics","result":"encoding_failed"}"#
    }

    private static func recordSystemAudioDiagnostics(_ event: SystemAudioDiagnosticsEvent) {
        let message = systemAudioDiagnosticsMessage(for: event)
        DiagnosticsSupport.record(category: "system-audio", message: message)
        Log.systemAudio.info("\(message, privacy: .public)")
    }

    private static func outputDeviceSnapshot(for deviceID: AudioDeviceID) -> (
        streamCount: Int?,
        nominalSampleRate: Double?,
        transportType: UInt32?
    ) {
        var streamAddress = propertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeOutput
        )
        var streamSize: UInt32 = 0
        let streamStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &streamAddress,
            0,
            nil,
            &streamSize
        )
        let streamCount = streamStatus == noErr
            ? Int(streamSize) / MemoryLayout<AudioStreamID>.size
            : nil

        var sampleRateAddress = propertyAddress(selector: kAudioDevicePropertyNominalSampleRate)
        var sampleRate = Float64(0)
        var sampleRateSize = UInt32(MemoryLayout<Float64>.size)
        let sampleRateStatus = AudioObjectGetPropertyData(
            deviceID,
            &sampleRateAddress,
            0,
            nil,
            &sampleRateSize,
            &sampleRate
        )

        var transportAddress = propertyAddress(selector: kAudioDevicePropertyTransportType)
        var transportType = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(
            deviceID,
            &transportAddress,
            0,
            nil,
            &transportSize,
            &transportType
        )

        return (
            streamCount: streamCount,
            nominalSampleRate: sampleRateStatus == noErr ? sampleRate : nil,
            transportType: transportStatus == noErr ? transportType : nil
        )
    }

    func bufferStream(outputDeviceID: AudioDeviceID? = nil) async throws -> CaptureStreams {
        await stop()

        let sysStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self._sysContinuation.withLock { $0 = continuation }
        }
        _hasCapturedFrames.value = false

        let resolvedDeviceID: AudioDeviceID
        let requestedOutputDeviceAvailable: Bool?
        if let requested = outputDeviceID {
            // Verify the requested device is still available; fall back to system default if not
            if (try? Self.deviceUID(for: requested)) != nil {
                resolvedDeviceID = requested
                requestedOutputDeviceAvailable = true
            } else {
                resolvedDeviceID = try Self.defaultOutputDeviceID()
                requestedOutputDeviceAvailable = false
            }
        } else {
            resolvedDeviceID = try Self.defaultOutputDeviceID()
            requestedOutputDeviceAvailable = nil
        }
        let outputUID = try Self.deviceUID(for: resolvedDeviceID)
        let outputSnapshot = Self.outputDeviceSnapshot(for: resolvedDeviceID)
        // #region system audio diagnostics
        Self.recordSystemAudioDiagnostics(
            SystemAudioDiagnosticsEvent(
                event: "system_audio_output_resolved",
                requestedOutputDeviceID: outputDeviceID,
                resolvedOutputDeviceID: resolvedDeviceID,
                outputDeviceAvailable: requestedOutputDeviceAvailable,
                outputDeviceUIDLength: outputUID.count,
                availableOutputDeviceCount: Self.availableOutputDevices().count,
                outputStreamCount: outputSnapshot.streamCount,
                outputNominalSampleRate: outputSnapshot.nominalSampleRate,
                outputTransportType: outputSnapshot.transportType
            )
        )
        // #endregion

        // Outer retry: recreate the tap from scratch if the format query keeps failing.
        // Some external USB/Bluetooth devices need more than one full tap creation cycle
        // before CoreAudio settles on a stable tap object.
        var lastError: Error = CaptureError.tapFormatUnavailable(kAudioHardwareBadObjectError)
        for attempt in 0..<3 {
            if attempt > 0 {
                // Honour cancellation before sleeping between attempts.
                try Task.checkCancellation()
                usleep(200_000)
                try Task.checkCancellation()
            }

            let tapUUID = UUID()
            let tapDescription = CATapDescription()
            tapDescription.name = "OpenOats System Audio"
            tapDescription.uuid = tapUUID
            let processObjectID = Self.currentProcessObjectID()
            tapDescription.processes = processObjectID.map { [$0] } ?? []
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted
            tapDescription.isMixdown = true
            tapDescription.isMono = true
            tapDescription.isExclusive = true
            tapDescription.deviceUID = outputUID

            var tapID = AudioObjectID(kAudioObjectUnknown)
            var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
            // #region system audio diagnostics
            Self.recordSystemAudioDiagnostics(
                SystemAudioDiagnosticsEvent(
                    event: "system_audio_process_tap_created",
                    attempt: attempt,
                    resolvedOutputDeviceID: resolvedDeviceID,
                    outputDeviceUIDLength: outputUID.count,
                    processObjectID: processObjectID,
                    processCount: tapDescription.processes.count,
                    tapID: tapID,
                    status: status,
                    flags: [
                        "isPrivate": tapDescription.isPrivate,
                        "isExclusive": tapDescription.isExclusive,
                        "isMixdown": tapDescription.isMixdown,
                        "isMono": tapDescription.isMono
                    ]
                )
            )
            // #endregion
            guard status == noErr else {
                _sysContinuation.withLock { $0?.finish(); $0 = nil }
                throw CaptureError.tapCreationFailed(status)
            }
            // Register immediately so a concurrent stop() can clean up this tap
            // even if we're still sleeping inside the format-query retry loop.
            let registeredTapID = tapID
            _tapID.withLock { $0 = registeredTapID }

            let aggregateUID = UUID().uuidString
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "OpenOats System Audio",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapUUID.uuidString,
                        kAudioSubTapDriftCompensationKey: true
                    ]
                ]
            ]

            var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateDeviceID
            )
            // #region system audio diagnostics
            Self.recordSystemAudioDiagnostics(
                SystemAudioDiagnosticsEvent(
                    event: "system_audio_aggregate_created",
                    attempt: attempt,
                    tapID: tapID,
                    aggregateDeviceID: aggregateDeviceID,
                    status: status,
                    flags: [
                        "isPrivate": true,
                        "tapAutoStart": true,
                        "tapDriftCompensation": true
                    ]
                )
            )
            // #endregion
            guard status == noErr else {
                _tapID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                _ = AudioHardwareDestroyProcessTap(tapID)
                _sysContinuation.withLock { $0?.finish(); $0 = nil }
                throw CaptureError.aggregateDeviceCreationFailed(status)
            }
            let registeredAggDeviceID = aggregateDeviceID
            _aggregateDeviceID.withLock { $0 = registeredAggDeviceID }

            let streamDescription: AudioStreamBasicDescription
            do {
                streamDescription = try await Self.tapStreamDescription(for: tapID, attempt: attempt)
            } catch {
                _aggregateDeviceID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                _tapID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                let da = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                let dt = AudioHardwareDestroyProcessTap(tapID)
                // #region system audio diagnostics
                Self.recordSystemAudioDiagnostics(
                    SystemAudioDiagnosticsEvent(
                        event: "system_audio_tap_format_failed_cleanup",
                        attempt: attempt,
                        tapID: tapID,
                        aggregateDeviceID: aggregateDeviceID,
                        cleanupAggregateStatus: da,
                        cleanupTapStatus: dt,
                        errorKind: Self.captureDiagnosticsErrorKind(for: error)
                    )
                )
                // #endregion
                if da != noErr { Log.systemAudio.warning("Tap format cleanup: DestroyAggregateDevice OSStatus \(da, privacy: .public)") }
                if dt != noErr { Log.systemAudio.warning("Tap format cleanup: DestroyProcessTap OSStatus \(dt, privacy: .public)") }
                // Retry only for the transient kAudioHardwareBadObjectError race.
                if case CaptureError.tapFormatUnavailable(kAudioHardwareBadObjectError) = error {
                    lastError = error
                    continue
                }
                // CancellationError or any other terminal failure — finish stream and propagate.
                _sysContinuation.withLock { $0?.finish(); $0 = nil }
                throw error
            }

            var mutableStreamDescription = streamDescription
            guard let format = AVAudioFormat(streamDescription: &mutableStreamDescription) else {
                _aggregateDeviceID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                _tapID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
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
            // #region system audio diagnostics
            Self.recordSystemAudioDiagnostics(
                SystemAudioDiagnosticsEvent(
                    event: "system_audio_io_proc_created",
                    attempt: attempt,
                    tapID: tapID,
                    aggregateDeviceID: aggregateDeviceID,
                    ioProcCreated: ioProcID != nil,
                    status: status
                )
            )
            // #endregion
            if status == kAudioHardwareBadObjectError {
                // Transient race on aggregate device registration — retry from scratch.
                _aggregateDeviceID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                _tapID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                let ds = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                let dt = AudioHardwareDestroyProcessTap(tapID)
                if ds != noErr { Log.systemAudio.warning("Retry cleanup (IOProc): DestroyAggregateDevice OSStatus \(ds, privacy: .public)") }
                if dt != noErr { Log.systemAudio.warning("Retry cleanup (IOProc): DestroyProcessTap OSStatus \(dt, privacy: .public)") }
                lastError = CaptureError.ioProcCreationFailed(status)
                continue
            }
            guard status == noErr, let ioProcID else {
                _aggregateDeviceID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                _tapID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                _ = AudioHardwareDestroyProcessTap(tapID)
                _sysContinuation.withLock { $0?.finish(); $0 = nil }
                throw CaptureError.ioProcCreationFailed(status)
            }

            status = AudioDeviceStart(aggregateDeviceID, ioProcID)
            // #region system audio diagnostics
            Self.recordSystemAudioDiagnostics(
                SystemAudioDiagnosticsEvent(
                    event: "system_audio_device_start_returned",
                    attempt: attempt,
                    tapID: tapID,
                    aggregateDeviceID: aggregateDeviceID,
                    status: status,
                    sampleRate: streamDescription.mSampleRate,
                    channels: streamDescription.mChannelsPerFrame,
                    bytesPerFrame: streamDescription.mBytesPerFrame
                )
            )
            // #endregion
            if status == kAudioHardwareBadObjectError {
                // Transient race on device start — retry from scratch.
                _aggregateDeviceID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                _tapID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                let ds = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                let da = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                let dt = AudioHardwareDestroyProcessTap(tapID)
                if ds != noErr { Log.systemAudio.warning("Retry cleanup (Start): DestroyIOProcID OSStatus \(ds, privacy: .public)") }
                if da != noErr { Log.systemAudio.warning("Retry cleanup (Start): DestroyAggregateDevice OSStatus \(da, privacy: .public)") }
                if dt != noErr { Log.systemAudio.warning("Retry cleanup (Start): DestroyProcessTap OSStatus \(dt, privacy: .public)") }
                lastError = CaptureError.startFailed(status)
                continue
            }
            guard status == noErr else {
                _aggregateDeviceID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                _tapID.withLock { $0 = AudioObjectID(kAudioObjectUnknown) }
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                _ = AudioHardwareDestroyProcessTap(tapID)
                _sysContinuation.withLock { $0?.finish(); $0 = nil }
                throw CaptureError.startFailed(status)
            }

            // tapID and aggregateDeviceID are already registered in their locks.
            _ioProcID.withLock { $0 = ioProcID }

            return CaptureStreams(systemAudio: sysStream)
        }

        _sysContinuation.withLock { $0?.finish(); $0 = nil }
        // #region system audio diagnostics
        Self.recordSystemAudioDiagnostics(
            SystemAudioDiagnosticsEvent(
                event: "system_audio_start_exhausted",
                retryCount: 3,
                errorKind: Self.captureDiagnosticsErrorKind(for: lastError)
            )
        )
        // #endregion
        throw lastError
    }

    /// Finish the async stream so consumers exit their for-await loop.
    /// Call this before stop() when you need a graceful drain.
    func finishStream() {
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
    }

    func stop() async {
        finishStream()
        _audioLevel.value = 0
        _hasCapturedFrames.value = false

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

        // Compute RMS audio level for the UI visualisation.
        if let channelData = pcmBuffer.floatChannelData, pcmBuffer.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(pcmBuffer.frameLength))
            _audioLevel.value = min(rms * 25, 1.0)
        }
        _hasCapturedFrames.value = true

        guard !_paused.value else { return }
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

    /// Returns a list of available output (speaker) audio devices.
    static func availableOutputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = propertyAddress(selector: kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []
        for deviceID in deviceIDs {
            // Check if this device has output streams
            var outputAddress = propertyAddress(selector: kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var outputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &outputAddress, 0, nil, &outputSize) == noErr, outputSize > 0 else { continue }

            // Get device name
            var nameAddress = propertyAddress(selector: kAudioObjectPropertyName)
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &cfName) == noErr, let name = cfName?.takeUnretainedValue() as String? else { continue }

            result.append((id: deviceID, name: name))
        }
        return result
    }

    /// Get the stable UID string for an output device.
    static func outputDeviceUID(for deviceID: AudioDeviceID) throws -> String {
        try deviceUID(for: deviceID)
    }

    /// Resolve a stable CoreAudio UID string back to the current AudioDeviceID, if the device is connected.
    static func outputDeviceID(forUID uid: String) -> AudioDeviceID? {
        for device in availableOutputDevices() {
            if (try? deviceUID(for: device.id)) == uid { return device.id }
        }
        return nil
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
        return uid.takeUnretainedValue() as String
    }

    private static func tapStreamDescription(
        for tapID: AudioObjectID,
        attempt: Int
    ) async throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector: kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        // Retry on kAudioHardwareBadObjectError — some hardware (external USB/Bluetooth
        // devices on M1/M2) needs up to ~3 s after AudioHardwareCreateProcessTap returns
        // before the tap object is fully resolvable.
        var status: OSStatus = noErr
        for retryIndex in 0..<40 {
            try Task.checkCancellation()
            status = AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &dataSize,
                &streamDescription
            )
            if status == noErr {
                // #region system audio diagnostics
                recordSystemAudioDiagnostics(
                    SystemAudioDiagnosticsEvent(
                        event: "system_audio_tap_format_resolved",
                        attempt: attempt,
                        tapID: tapID,
                        status: status,
                        retryIndex: retryIndex,
                        sampleRate: streamDescription.mSampleRate,
                        channels: streamDescription.mChannelsPerFrame,
                        bytesPerFrame: streamDescription.mBytesPerFrame
                    )
                )
                // #endregion
                return streamDescription
            }
            if status != kAudioHardwareBadObjectError { break }
            try await Task.sleep(nanoseconds: 75_000_000)
        }
        // #region system audio diagnostics
        recordSystemAudioDiagnostics(
            SystemAudioDiagnosticsEvent(
                event: "system_audio_tap_format_exhausted",
                attempt: attempt,
                tapID: tapID,
                status: status,
                retryCount: 40
            )
        )
        // #endregion
        throw CaptureError.tapFormatUnavailable(status)
    }

    private static func captureDiagnosticsErrorKind(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }

        if let captureError = error as? CaptureError {
            switch captureError {
            case .noOutputDevice:
                return "no_output_device"
            case .outputDeviceUIDUnavailable(let status):
                return "output_device_uid_unavailable_\(status)"
            case .tapCreationFailed(let status):
                return "tap_creation_failed_\(status)"
            case .aggregateDeviceCreationFailed(let status):
                return "aggregate_device_creation_failed_\(status)"
            case .tapFormatUnavailable(let status):
                return "tap_format_unavailable_\(status)"
            case .invalidTapFormat:
                return "invalid_tap_format"
            case .ioProcCreationFailed(let status):
                return "io_proc_creation_failed_\(status)"
            case .startFailed(let status):
                return "start_failed_\(status)"
            }
        }

        return "other"
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
