@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio via AVAudioEngine and streams PCM buffers.
///
/// Creates a fresh AVAudioEngine for each `bufferStream()` call, which avoids
/// stale format state during device switches (e.g. AirPods connect/disconnect).
/// Device selection is set via AudioUnit property before the engine starts.
final class MicCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var hasTapInstalled = false
    private let _audioLevel = AudioLevel()
    private let _error = SyncString()
    private let continuationLock = NSLock()
    private let callbackLock = NSLock()
    private var continuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var onBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?

    /// Tap-thread-only counter box. A fresh box per bufferStream() call means the
    /// render thread never races the main thread over a shared property.
    private final class ChunkCounter: @unchecked Sendable {
        var count = 0
    }

    var audioLevel: Float { _audioLevel.value }
    var captureError: String? { _error.value }

    func bufferStream(
        deviceID: AudioDeviceID? = nil,
        onBuffer: (@Sendable (CapturedAudioBuffer) -> Void)? = nil
    ) -> AsyncStream<CapturedAudioBuffer> {
        // Defensive cleanup of any prior state
        continuationLock.withLock { continuation?.finish(); continuation = nil }
        callbackLock.withLock { self.onBuffer = onBuffer }

        let stream = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(32)) { continuation in
            self._error.value = nil
            self.continuationLock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { _ in
                diagLog("[MIC-TERM] stream terminated")
            }
        }

        diagLog("[MIC-1] bufferStream called, deviceID=\(String(describing: deviceID))")

        let freshEngine = makeFreshEngine()
        let inputNode = freshEngine.inputNode

        // Set input device before accessing inputNode format
        var resolvedDeviceID: AudioDeviceID?
        if let id = deviceID {
            guard let inAU = inputNode.audioUnit else {
                let msg = "inputNode has no audio unit"
                diagLog("[MIC-FAIL] \(msg)")
                _error.value = msg
                continuationLock.withLock { continuation?.finish(); continuation = nil }
                return stream
            }
            var devID = id
            let status = AudioUnitSetProperty(
                inAU,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            diagLog("[MIC-2] setInputDevice status=\(status) (0=ok)")
            resolvedDeviceID = id
        } else {
            resolvedDeviceID = Self.defaultInputDeviceID()
        }

        let format = inputNode.outputFormat(forBus: 0)

        // The hardware nominal rate can differ from what the inputNode reports right
        // after a device switch (the node format lags). We must NOT install the tap
        // at a rate different from the node's format — AVAudioEngine raises an
        // uncatchable NSException ("format.sampleRate == hwFormat.sampleRate") and
        // the app crashes. Log the divergence for diagnostics only; downstream
        // consumers (PCMFileWriter conversion, StreamingTranscriber's cadence-based
        // rate correction, TimingAwareStemRebuilder) all handle mistagged rates.
        if let devID = resolvedDeviceID,
           let hwRate = Self.deviceNominalSampleRate(for: devID),
           hwRate > 0, hwRate != format.sampleRate {
            diagLog("[MIC-3] hardware sr=\(hwRate) differs from inputNode sr=\(format.sampleRate); tapping at node rate, downstream corrects")
        }

        diagLog("[MIC-3] inputNode format: sr=\(format.sampleRate) ch=\(format.channelCount) interleaved=\(format.isInterleaved)")

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            let msg = "Invalid audio format: sr=\(format.sampleRate) ch=\(format.channelCount)"
            diagLog("[MIC-FAIL] \(msg)")
            _error.value = msg
            continuationLock.withLock { continuation?.finish(); continuation = nil }
            return stream
        }

        // Prefer mono at the NODE's sample rate — it's what the transcriber needs,
        // and multi-channel formats (e.g. MacBook Air's 3-element mic array) can
        // cause issues downstream. The tap format's sample rate must always equal
        // the node's output sample rate (see crash note above).
        let tapFormat: AVAudioFormat
        if let f = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) {
            tapFormat = f
        } else {
            diagLog("[MIC-4] standard mono format failed, using native input format")
            tapFormat = format
        }

        diagLog("[MIC-4] tapFormat: sr=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount)")

        let level = _audioLevel
        let counter = ChunkCounter()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self, buffer.frameLength > 0 else { return }

            counter.count += 1
            let count = counter.count
            let rms = Self.normalizedRMS(from: buffer)
            level.value = min(rms * 25, 1.0)

            if count <= 5 || count % 100 == 0 {
                diagLog("[MIC-6] tap #\(count): frames=\(buffer.frameLength) rms=\(rms) level=\(level.value)")
            }

            let capturedBuffer = CapturedAudioBuffer(buffer: buffer, capturedAt: Date())

            let callback = self.callbackLock.withLock { self.onBuffer }
            callback?(capturedBuffer)

            let cont = self.continuationLock.withLock { self.continuation }
            _ = cont?.yield(capturedBuffer)
        }
        hasTapInstalled = true

        do {
            try freshEngine.start()
            diagLog("[MIC-5] engine started, isRunning=\(freshEngine.isRunning)")
        } catch {
            let msg = "Mic failed: \(error.localizedDescription)"
            diagLog("[MIC-FAIL] \(msg)")
            _error.value = msg
            hasTapInstalled = false
            callbackLock.withLock { self.onBuffer = nil }
            continuationLock.withLock { continuation?.finish(); continuation = nil }
        }

        return stream
    }

    func finishStream() {
        continuationLock.withLock {
            continuation?.finish()
            continuation = nil
        }
        callbackLock.withLock { onBuffer = nil }
    }

    func stop() {
        diagLog("[MIC-STOP] begin")
        finishStream()
        if hasTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        engine.stop()
        engine.reset()
        _audioLevel.value = 0
        diagLog("[MIC-STOP] end")
    }

    private func makeFreshEngine() -> AVAudioEngine {
        if hasTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        engine.stop()
        let freshEngine = AVAudioEngine()
        engine = freshEngine
        return freshEngine
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            if channelCount == 1 || buffer.format.isInterleaved {
                let totalSamples = buffer.format.isInterleaved ? frameLength * channelCount : frameLength
                var sum: Float = 0
                for i in 0..<totalSamples {
                    let s = channelData[0][i]
                    sum += s * s
                }
                return sqrt(sum / Float(totalSamples))
            } else {
                var totalSum: Float = 0
                for ch in 0..<channelCount {
                    for i in 0..<frameLength {
                        let s = channelData[ch][i]
                        totalSum += s * s
                    }
                }
                return sqrt(totalSum / Float(frameLength * channelCount))
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            var sum: Float = 0
            for i in 0..<frameLength {
                let s = Float(channelData[0][i]) * scale
                sum += s * s
            }
            return sqrt(sum / Float(frameLength))
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            var sum: Float = 0
            for i in 0..<frameLength {
                let s = Float(channelData[0][i]) * scale
                sum += s * s
            }
            return sqrt(sum / Float(frameLength))
        }

        return 0
    }

    // MARK: - Hardware Sample Rate Query

    /// Query the nominal sample rate of a CoreAudio device directly from hardware.
    static func deviceNominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : nil
    }

    // MARK: - List available input devices

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []

        for deviceID in deviceIDs {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
            guard status == noErr, bufferListSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr)
            guard status == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            guard let name = deviceName(for: deviceID) else { continue }
            let uid = deviceUID(for: deviceID) ?? ""
            let transportType = deviceTransportType(for: deviceID)
            guard !isExcludedInputDevice(name: name, uid: uid, transportType: transportType) else {
                continue
            }
            result.append((id: deviceID, name: name))
        }

        return result
    }

    static func automaticInputDeviceID() -> AudioDeviceID? {
        let devices = availableInputDevices()
        guard !devices.isEmpty else { return defaultInputDeviceID() }

        if let builtInMicID = preferredBuiltInMicrophoneID(from: devices) {
            return builtInMicID
        }

        let defaultID = defaultInputDeviceID()
        let ranked = devices
            .map { device in
                (
                    device: device,
                    score: deviceSelectionScore(
                        for: device.name,
                        isOSDefault: device.id == defaultID,
                        transportType: deviceTransportType(for: device.id)
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.device.name.localizedCaseInsensitiveCompare(rhs.device.name) == .orderedAscending
            }

        return ranked.first?.device.id ?? defaultID
    }

    static func automaticInputDeviceName() -> String? {
        guard let id = automaticInputDeviceID() else { return nil }
        return deviceName(for: id)
    }

    static func inputDeviceName(for deviceID: AudioDeviceID) -> String? {
        deviceName(for: deviceID)
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func deviceTransportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        return status == noErr ? transportType : nil
    }

    private static func deviceSelectionScore(
        for deviceName: String,
        isOSDefault: Bool,
        transportType: UInt32?
    ) -> Int {
        let lowered = deviceName.lowercased()

        var score = 0

        if isOSDefault { score += 20 }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: score += 140
        case kAudioDeviceTransportTypeUSB: score += 100
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: score -= 80
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: score -= 160
        default: break
        }

        if ["microphone", "built-in"].contains(where: lowered.contains) { score += 120 }
        if ["mic", "input", "headset"].contains(where: lowered.contains) { score += 45 }
        if ["background music", "ui sounds", "zoomaudiodevice", "loopback", "blackhole", "soundflower", "virtual", "bass"].contains(where: lowered.contains) { score -= 120 }
        if lowered.contains("airpods") || lowered.contains("buds") { score -= 60 }

        return score
    }

    private static func preferredBuiltInMicrophoneID(
        from devices: [(id: AudioDeviceID, name: String)]
    ) -> AudioDeviceID? {
        if let exactBuiltIn = devices.first(where: { deviceUID(for: $0.id) == "BuiltInMicrophoneDevice" }) {
            return exactBuiltIn.id
        }
        if let macbookMic = devices.first(where: {
            let lowered = $0.name.lowercased()
            return lowered.contains("macbook") && lowered.contains("microphone")
        }) {
            return macbookMic.id
        }
        if let genericBuiltInMic = devices.first(where: {
            deviceTransportType(for: $0.id) == kAudioDeviceTransportTypeBuiltIn &&
                $0.name.lowercased().contains("microphone")
        }) {
            return genericBuiltInMic.id
        }
        return nil
    }

    private static func isExcludedInputDevice(
        name: String,
        uid: String,
        transportType: UInt32?
    ) -> Bool {
        let loweredName = name.lowercased()
        let loweredUID = uid.lowercased()

        if loweredName.contains("gelato system audio") || loweredUID.contains("com.gelato.system-audio") {
            return true
        }

        if transportType == kAudioDeviceTransportTypeAggregate || transportType == kAudioDeviceTransportTypeAutoAggregate,
           !loweredName.contains("microphone"),
           !loweredName.contains("mic"),
           !loweredName.contains("headset") {
            return true
        }

        return false
    }
}

/// Simple thread-safe float holder for audio level.
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe optional string holder.
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
