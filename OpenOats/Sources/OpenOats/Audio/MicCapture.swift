@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

private let micLog = Logger(subsystem: "com.openoats", category: "MicCapture")

/// Captures microphone audio via AVAudioEngine and streams PCM buffers.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let _audioLevel = AudioLevel()
    private let _hasCapturedFrames = SyncBool()
    private let _error = SyncString()
    private let _streamContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)

    var audioLevel: Float { _audioLevel.value }
    var hasCapturedFrames: Bool { _hasCapturedFrames.value }
    var captureError: String? { _error.value }

    /// Set a specific input device by its AudioDeviceID. Pass nil to use system default.
    func setInputDevice(_ deviceID: AudioDeviceID?) {
        guard let id = deviceID else { return }
        let audioUnit = engine.inputNode.audioUnit!
        var deviceID = id
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    func bufferStream(deviceID: AudioDeviceID? = nil) -> AsyncStream<AVAudioPCMBuffer> {
        // Defensive cleanup of any prior state
        _streamContinuation.withLock { $0?.finish(); $0 = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let level = _audioLevel
        let errorHolder = _error

        return AsyncStream { continuation in
            self._streamContinuation.withLock { $0 = continuation }
            errorHolder.value = nil
            self._hasCapturedFrames.value = false

            diagLog("[MIC-1] bufferStream called, deviceID=\(String(describing: deviceID))")

            // Resolve the target device ID (explicit or system default)
            let targetDevID: AudioDeviceID
            if let id = deviceID {
                targetDevID = id
            } else if let defaultID = Self.defaultInputDeviceID() {
                targetDevID = defaultID
            } else {
                let msg = "No input device available"
                diagLog("[MIC-2-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }

            // Prepare the engine first so audioUnit properties are available.
            // reset() destroys audio units, so we must prepare() before
            // accessing .audioUnit on any node.
            self.engine.reset()
            self.engine.prepare()

            let inputNode = self.engine.inputNode

            // Set input device before accessing inputNode format
            guard let inAU = inputNode.audioUnit else {
                let msg = "inputNode has no audio unit after prepare"
                diagLog("[MIC-2-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }

            var devID = targetDevID
            let outputChannels = Self.channelCount(for: targetDevID, scope: kAudioDevicePropertyScopeOutput)
            // For input-only devices, explicit AU device binding is fragile and
            // repeatedly fails at engine.start (-10875 / !dev). Let AVAudioEngine
            // negotiate routing itself instead of forcing CurrentDevice.
            let shouldBindDevices = outputChannels > 0
            if shouldBindDevices {
                let inStatus = AudioUnitSetProperty(
                    inAU,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                diagLog("[MIC-2] setInputDevice status=\(inStatus) (0=ok)")
            } else {
                diagLog("[MIC-2] skipping explicit input device set for input-only target")
            }

            // Only force outputNode device when the selected mic device can output.
            // Input-only devices trigger engine.start failures if assigned to output.
            if shouldBindDevices, let outAU = self.engine.outputNode.audioUnit {
                devID = targetDevID
                let outStatus = AudioUnitSetProperty(
                    outAU,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                diagLog("[MIC-2b] setOutputDevice status=\(outStatus) (0=ok)")
            } else {
                diagLog("[MIC-2b] skipping output device set (outputChannels=\(outputChannels))")
            }

            let format = inputNode.outputFormat(forBus: 0)

            diagLog("[MIC-3] inputNode format: sr=\(format.sampleRate) ch=\(format.channelCount) interleaved=\(format.isInterleaved) commonFormat=\(format.commonFormat.rawValue)")

            guard format.sampleRate > 0 && format.channelCount > 0 else {
                let msg = "Invalid audio format: sr=\(format.sampleRate) ch=\(format.channelCount)"
                diagLog("[MIC-3-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }

            guard let tapFormat = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate,
                channels: format.channelCount
            ) else {
                let msg = "Failed to build tap format from input format"
                diagLog("[MIC-4-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }

            diagLog("[MIC-4] tapFormat: sr=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount)")

            if shouldBindDevices {
                // Connect inputNode → mainMixerNode to establish the audio pull chain.
                // Use nil format so CoreAudio negotiates the hardware-native stream format.
                let mixer = self.engine.mainMixerNode
                self.engine.connect(inputNode, to: mixer, format: nil)
                mixer.volume = 0   // Don't play mic input through speakers
                diagLog("[MIC-4b] connected inputNode → mainMixer (volume=0)")
            } else {
                diagLog("[MIC-4b] skipping inputNode → mainMixer connect for input-only routing")
            }

            var tapCallCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
                tapCallCount += 1
                self._hasCapturedFrames.value = true
                let rms = Self.normalizedRMS(from: buffer)
                level.value = min(rms * 25, 1.0)

                if tapCallCount <= 5 || tapCallCount % 100 == 0 {
                    diagLog("[MIC-6] tap #\(tapCallCount): frames=\(buffer.frameLength) rms=\(rms) level=\(level.value)")
                }

                continuation.yield(buffer)
            }

            diagLog("[MIC-5] tap installed, preparing engine...")

            continuation.onTermination = { _ in
                diagLog("[MIC-TERM] stream terminated")
                // Audio hardware teardown handled by stop() — not here,
                // so finishStream() can drain without premature engine shutdown.
            }

            do {
                diagLog("[MIC-7] starting engine...")
                try self.engine.start()
                diagLog("[MIC-8] engine started successfully, isRunning=\(self.engine.isRunning)")
            } catch {
                let msg = "Mic failed: \(error.localizedDescription)"
                print("[MIC-8-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
            }
        }
    }

    /// Finish the async stream so consumers exit their for-await loop.
    /// Call this before stop() when you need a graceful drain.
    func finishStream() {
        _streamContinuation.withLock { $0?.finish(); $0 = nil }
    }

    func stop() {
        finishStream()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        _audioLevel.value = 0
        _hasCapturedFrames.value = false
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return channelData[0][(frame * stride) + channel]
                }
                return channelData[channel][frame]
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        return 0
    }

    private static func rms(
        frameLength: Int,
        channelCount: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> Float {
        var sum: Float = 0

        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let s = sampleAt(frame, channel)
                sum += s * s
            }
        }

        let sampleCount = Float(frameLength * channelCount)
        return sampleCount > 0 ? sqrt(sum / sampleCount) : 0
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
            // Check if device has input channels
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

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
            guard status == noErr, let nameVal = nameRef?.takeUnretainedValue() else { continue }

            result.append((id: deviceID, name: nameVal as String))
        }

        return result
    }

    /// Convert a CoreAudio AudioDeviceID to the UID string used by ScreenCaptureKit.
    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uidRef)
        return status == noErr ? uidRef?.takeUnretainedValue() as String? : nil
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

    private static func channelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var bufferListSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &bufferListSize)
        guard sizeStatus == noErr, bufferListSize > 0 else { return 0 }

        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPtr.deallocate() }

        var mutableSize = bufferListSize
        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &mutableSize, bufferListPtr)
        guard dataStatus == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
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

/// Simple thread-safe bool holder.
final class SyncBool: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
