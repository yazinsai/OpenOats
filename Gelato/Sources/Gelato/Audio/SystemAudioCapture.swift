@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Captures system audio using a Core Audio process tap instead of ScreenCaptureKit.
final class SystemAudioCapture: @unchecked Sendable {
    private let stateLock = NSLock()
    private let continuationLock = NSLock()
    private let callbackLock = NSLock()
    /// Serializes capture lifecycle transitions (start/stop) so a restart racing a
    /// stop can never double-destroy CoreAudio objects or orphan a live tap.
    private let controlLock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.gelato.system-audio.tap")
    private let deliveryQueue = DispatchQueue(label: "com.gelato.system-audio.delivery")
    private let _audioLevel = AudioLevel()

    private var continuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var onSystemBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?

    private var processTap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var accumulator: PCMChunkAccumulator?
    /// Confined to deliveryQueue — only touched from deliveryQueue blocks.
    private var sampleRateResolver: SystemTapSampleRateResolver?
    private var captureGeneration = UUID()
    private var deliveredChunkCount = 0

    var audioLevel: Float { _audioLevel.value }

    struct CaptureStreams {
        let systemAudio: AsyncStream<CapturedAudioBuffer>
    }

    func bufferStream(
        onSystemBuffer: (@Sendable (CapturedAudioBuffer) -> Void)? = nil
    ) async throws -> CaptureStreams {
        try startStreamSynchronized(onSystemBuffer: onSystemBuffer)
    }

    private func startStreamSynchronized(
        onSystemBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?
    ) throws -> CaptureStreams {
        controlLock.lock()
        defer { controlLock.unlock() }

        stopLocked()

        let generation = UUID()
        callbackLock.withLock {
            self.onSystemBuffer = onSystemBuffer
        }

        let stream = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(32)) { continuation in
            self.continuationLock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.continuationLock.withLock {
                    self?.continuation = nil
                }
            }
        }

        do {
            try startCapture(generation: generation)
            return CaptureStreams(systemAudio: stream)
        } catch {
            continuationLock.withLock {
                continuation?.finish()
                continuation = nil
            }
            callbackLock.withLock {
                self.onSystemBuffer = nil
            }
            throw error
        }
    }

    func finishStream() {
        continuationLock.withLock {
            continuation?.finish()
            continuation = nil
        }
        callbackLock.withLock {
            onSystemBuffer = nil
        }
    }

    func stop() async {
        stopSynchronized()
    }

    private func stopSynchronized() {
        controlLock.lock()
        defer { controlLock.unlock() }
        stopLocked()
        finishStream()
    }

    /// Caller must hold `controlLock`.
    private func stopLocked() {
        // Take-and-clear the capture objects atomically: a second stop (or a stop
        // racing a restart) sees nil and destroys nothing.
        let captureState = stateLock.withLock { () -> CaptureState in
            let state = CaptureState(
                processTap: processTap,
                aggregateDevice: aggregateDevice,
                ioProcID: ioProcID,
                format: tapFormat,
                generation: captureGeneration
            )
            processTap = nil
            aggregateDevice = nil
            ioProcID = nil
            return state
        }

        if let aggregateDevice = captureState.aggregateDevice,
           let ioProcID = captureState.ioProcID {
            let stopStatus = AudioDeviceStop(aggregateDevice.id, ioProcID)
            if stopStatus != noErr {
                diagLog("[SYS-TAP-STOP-FAIL] status=\(stopStatus)")
            }
        }

        // Flush the accumulator tail and resolver-buffered chunks while the
        // continuation and recorder callback are still wired up — finishing the
        // stream first would silently drop the final ~0.5s of system audio on
        // every stop and device switch.
        let pendingChunk = ioQueue.sync { () -> PendingPCMChunk? in
            stateLock.withLock {
                let chunk = accumulator?.flush()
                accumulator = nil
                return chunk
            }
        }

        deliveryQueue.sync {
            if let pendingChunk {
                handleDeliveredChunk(pendingChunk, fallbackFormat: captureState.format)
            }
            flushBufferedChunks(fallbackFormat: captureState.format)
            deliveredChunkCount = 0
        }

        if let aggregateDevice = captureState.aggregateDevice,
           let ioProcID = captureState.ioProcID {
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
            if destroyStatus != noErr {
                diagLog("[SYS-TAP-IOPROC-DESTROY-FAIL] status=\(destroyStatus)")
            }
        }

        if let aggregateDevice = captureState.aggregateDevice {
            do {
                try AudioHardwareSystem.shared.destroyAggregateDevice(aggregateDevice)
            } catch {
                diagLog("[SYS-TAP-AGG-DESTROY-FAIL] \(error.localizedDescription)")
            }
        }

        if let processTap = captureState.processTap {
            do {
                try AudioHardwareSystem.shared.destroyProcessTap(processTap)
            } catch {
                diagLog("[SYS-TAP-DESTROY-FAIL] \(error.localizedDescription)")
            }
        }

        stateLock.withLock {
            tapFormat = nil
            accumulator = nil
            captureGeneration = UUID()
        }
        _audioLevel.value = 0
    }

    private func startCapture(generation: UUID) throws {
        let system = AudioHardwareSystem.shared

        guard let outputDevice = try system.defaultOutputDevice else {
            throw CaptureError.noDefaultOutputDevice
        }

        let outputUID = try outputDevice.uid
        let outputStreamIndex = try Self.firstOutputStreamIndex(for: outputDevice)
        let excludedProcessIDs = Self.excludedProcessIDs(system: system)

        let tapDescription = CATapDescription(
            excludingProcesses: excludedProcessIDs,
            deviceUID: outputUID,
            stream: outputStreamIndex
        )
        tapDescription.name = "Gelato System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        tapDescription.isMixdown = true
        tapDescription.isMono = true
        tapDescription.isExclusive = true

        guard let processTap = try system.makeProcessTap(description: tapDescription) else {
            throw CaptureError.tapCreationFailed
        }

        let tapUID = try processTap.uid
        var tapStreamDescription = try processTap.format
        if let nominalSampleRate = Self.nominalSampleRate(for: outputDevice.id),
           nominalSampleRate > 0,
           abs(tapStreamDescription.mSampleRate - nominalSampleRate) > 1 {
            diagLog(
                "[SYS-TAP-RATE] overriding tap sample rate " +
                "from \(tapStreamDescription.mSampleRate) to nominal \(nominalSampleRate)"
            )
            tapStreamDescription.mSampleRate = nominalSampleRate
        }
        guard let tapFormat = AVAudioFormat(streamDescription: &tapStreamDescription) else {
            try? system.destroyProcessTap(processTap)
            throw CaptureError.invalidTapFormat
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "com.gelato.system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Gelato System Audio",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
            try? system.destroyProcessTap(processTap)
            throw CaptureError.aggregateDeviceCreationFailed
        }

        let accumulator = try PCMChunkAccumulator(
            format: tapFormat,
            targetFrameCount: 4096,
            generation: generation
        )
        // sampleRateResolver is confined to deliveryQueue.
        deliveryQueue.sync {
            self.sampleRateResolver = SystemTapSampleRateResolver(reportedFormat: tapFormat)
        }
        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDevice.id,
            ioQueue
        ) { [weak self] inNow, inputData, inputTime, _, _ in
            self?.handleInputData(
                inputData,
                inputTime: inputTime,
                fallbackTime: inNow
            )
        }

        guard createStatus == noErr, let ioProcID else {
            try? system.destroyAggregateDevice(aggregateDevice)
            try? system.destroyProcessTap(processTap)
            throw CaptureError.ioProcCreationFailed(status: createStatus)
        }

        let startStatus = AudioDeviceStart(aggregateDevice.id, ioProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
            try? system.destroyAggregateDevice(aggregateDevice)
            try? system.destroyProcessTap(processTap)
            throw CaptureError.startFailed(status: startStatus)
        }

        stateLock.withLock {
            self.processTap = processTap
            self.aggregateDevice = aggregateDevice
            self.ioProcID = ioProcID
            self.tapFormat = tapFormat
            self.accumulator = accumulator
            self.captureGeneration = generation
            self.deliveredChunkCount = 0
        }

        diagLog(
            "[SYS-TAP-START] output=\(outputUID) stream=\(outputStreamIndex) " +
            "sr=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount) interleaved=\(tapFormat.isInterleaved)"
        )
    }

    private func handleInputData(
        _ inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>?,
        fallbackTime: UnsafePointer<AudioTimeStamp>?
    ) {
        let capturedAt = Self.captureDate(inputTime: inputTime, fallbackTime: fallbackTime)
        let pendingChunk = stateLock.withLock { accumulator?.append(inputData, capturedAt: capturedAt) }
        guard let pendingChunk else { return }

        deliveryQueue.async { [weak self] in
            guard let self else { return }
            let fallbackFormat = self.stateLock.withLock { self.tapFormat }
            self.handleDeliveredChunk(pendingChunk, fallbackFormat: fallbackFormat)
        }
    }

    private func handleDeliveredChunk(_ chunk: PendingPCMChunk, fallbackFormat: AVAudioFormat?) {
        guard let resolver = sampleRateResolver else {
            deliver(chunk: chunk, format: fallbackFormat)
            return
        }

        let resolved = resolver.append(chunk)
        for deliverableChunk in resolved.chunks {
            deliver(chunk: deliverableChunk, format: resolved.format ?? fallbackFormat)
        }
    }

    private func flushBufferedChunks(fallbackFormat: AVAudioFormat?) {
        guard let resolver = sampleRateResolver else { return }
        let resolved = resolver.drain(fallbackFormat: fallbackFormat)
        sampleRateResolver = nil

        for deliverableChunk in resolved.chunks {
            deliver(chunk: deliverableChunk, format: resolved.format)
        }
    }

    private func deliver(chunk: PendingPCMChunk, format: AVAudioFormat?) {
        guard stateLock.withLock({ chunk.generation == captureGeneration }) else { return }
        guard let format, let buffer = chunk.makePCMBuffer(format: format) else { return }

        deliveredChunkCount += 1
        let count = deliveredChunkCount
        let rms = Self.normalizedRMS(from: buffer)
        _audioLevel.value = min(rms * 8, 1.0)
        if count <= 5 || count % 50 == 0 {
            diagLog("[SYS-TAP] #\(count) frames=\(buffer.frameLength) rms=\(rms)")
        }

        let capturedBuffer = CapturedAudioBuffer(buffer: buffer, capturedAt: chunk.capturedAt)

        let callback = callbackLock.withLock { onSystemBuffer }
        callback?(capturedBuffer)

        let continuation = continuationLock.withLock { self.continuation }
        _ = continuation?.yield(capturedBuffer)
    }

    private static func captureDate(
        inputTime: UnsafePointer<AudioTimeStamp>?,
        fallbackTime: UnsafePointer<AudioTimeStamp>?
    ) -> Date {
        let hostTimeValidFlag: UInt32 = 1 << 1

        if let inputTime,
           (inputTime.pointee.mFlags.rawValue & hostTimeValidFlag) != 0 {
            return CaptureClock.date(forHostTime: inputTime.pointee.mHostTime)
        }

        if let fallbackTime,
           (fallbackTime.pointee.mFlags.rawValue & hostTimeValidFlag) != 0 {
            return CaptureClock.date(forHostTime: fallbackTime.pointee.mHostTime)
        }

        return Date()
    }

    private static func excludedProcessIDs(system: AudioHardwareSystem) -> [AudioObjectID] {
        if let process = try? system.process(for: getpid()) {
            return [process.id]
        }
        return []
    }

    private static func firstOutputStreamIndex(for device: AudioHardwareDevice) throws -> UInt {
        let streams = try device.streams
        for (index, stream) in streams.enumerated() where try stream.direction == .output {
            return UInt(index)
        }
        throw CaptureError.noOutputStream
    }

    private static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0, nil,
            &size,
            &sampleRate
        )
        return status == noErr ? sampleRate : nil
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
                let sample = sampleAt(frame, channel)
                sum += sample * sample
            }
        }

        let sampleCount = Float(frameLength * channelCount)
        return sampleCount > 0 ? sqrt(sum / sampleCount) : 0
    }

    private struct CaptureState {
        let processTap: AudioHardwareTap?
        let aggregateDevice: AudioHardwareAggregateDevice?
        let ioProcID: AudioDeviceIOProcID?
        let format: AVAudioFormat?
        let generation: UUID
    }

    enum CaptureError: LocalizedError {
        case noDefaultOutputDevice
        case noOutputStream
        case tapCreationFailed
        case invalidTapFormat
        case aggregateDeviceCreationFailed
        case ioProcCreationFailed(status: OSStatus)
        case startFailed(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .noDefaultOutputDevice:
                return "No default output device is available for system audio capture."
            case .noOutputStream:
                return "The default output device has no output stream to tap."
            case .tapCreationFailed:
                return "macOS could not create the system-audio process tap."
            case .invalidTapFormat:
                return "macOS returned an invalid format for the system-audio tap."
            case .aggregateDeviceCreationFailed:
                return "macOS could not create the private aggregate device for system audio capture."
            case .ioProcCreationFailed(let status):
                return "macOS could not attach an IO callback to the system-audio device (\(status))."
            case .startFailed(let status):
                return "macOS could not start the system-audio device (\(status))."
            }
        }
    }
}

private final class SystemTapSampleRateResolver {
    private static let minimumObservedRates = 3
    private static let maximumBufferedChunks = 6
    private static let correctionThresholdRatio = 0.05
    /// Post-resolution rolling window: ~1s of chunks must sustain a divergent
    /// cadence before the resolved rate is corrected mid-capture.
    private static let postResolutionWindow = 12
    private static let reResolutionDivergenceRatio = 0.05
    private static let canonicalRates: [Double] = [
        8_000,
        12_000,
        16_000,
        22_050,
        24_000,
        32_000,
        44_100,
        48_000
    ]

    private let reportedFormat: AVAudioFormat
    private var previousChunk: PendingPCMChunk?
    private var observedRates: [Double] = []
    private var bufferedChunks: [PendingPCMChunk] = []
    private var resolvedFormat: AVAudioFormat?
    private var postResolutionRates: [Double] = []

    init(reportedFormat: AVAudioFormat) {
        self.reportedFormat = reportedFormat
    }

    func append(_ chunk: PendingPCMChunk) -> ResolvedDelivery {
        if resolvedFormat != nil {
            // Keep watching the delivery cadence after resolution: a Bluetooth
            // profile flip (A2DP <-> HFP) changes the device's real rate without
            // any device-change notification, and every buffer stays tagged with
            // the stale rate. Re-resolve when the divergence is sustained.
            trackPostResolutionCadence(chunk)
            previousChunk = chunk
            return ResolvedDelivery(format: resolvedFormat, chunks: [chunk])
        }

        if let previousChunk {
            let delta = chunk.capturedAt.timeIntervalSince(previousChunk.capturedAt)
            if delta > 0 {
                observedRates.append(Double(previousChunk.frameCount) / delta)
            }
        }
        previousChunk = chunk
        bufferedChunks.append(chunk)

        let shouldForceResolution = bufferedChunks.count >= Self.maximumBufferedChunks
        guard let format = resolveFormat(force: shouldForceResolution) else {
            return ResolvedDelivery(format: nil, chunks: [])
        }

        let chunks = bufferedChunks
        bufferedChunks = []
        return ResolvedDelivery(format: format, chunks: chunks)
    }

    private func trackPostResolutionCadence(_ chunk: PendingPCMChunk) {
        guard let previousChunk, let current = resolvedFormat else { return }
        let delta = chunk.capturedAt.timeIntervalSince(previousChunk.capturedAt)
        guard delta > 0 else { return }

        let rate = Double(previousChunk.frameCount) / delta
        guard rate.isFinite, rate >= 4_000, rate <= 192_000 else { return }

        postResolutionRates.append(rate)
        if postResolutionRates.count > Self.postResolutionWindow {
            postResolutionRates.removeFirst(postResolutionRates.count - Self.postResolutionWindow)
        }
        guard postResolutionRates.count >= Self.postResolutionWindow else { return }

        let median = Self.median(of: postResolutionRates)
        guard let snappedRate = Self.snapToCanonicalRate(median) else { return }

        let divergence = abs(snappedRate - current.sampleRate) / max(current.sampleRate, 1)
        guard divergence >= Self.reResolutionDivergenceRatio,
              let correctedFormat = Self.makeFormat(from: current, sampleRate: snappedRate) else {
            return
        }

        diagLog("[SYS-TAP-RATE-RERESOLVED] \(current.sampleRate) -> \(snappedRate) mid-capture")
        resolvedFormat = correctedFormat
        postResolutionRates.removeAll()
    }

    func drain(fallbackFormat: AVAudioFormat?) -> ResolvedDelivery {
        let format = resolveFormat(force: true) ?? fallbackFormat
        let chunks = bufferedChunks
        bufferedChunks = []
        previousChunk = nil
        observedRates = []
        return ResolvedDelivery(format: format, chunks: chunks)
    }

    private func resolveFormat(force: Bool) -> AVAudioFormat? {
        if let resolvedFormat {
            return resolvedFormat
        }

        guard force || observedRates.count >= Self.minimumObservedRates else {
            return nil
        }

        guard let measuredRate = measuredRate() else {
            resolvedFormat = reportedFormat
            diagLog("[SYS-TAP-RATE-DETECTED] keeping reported rate \(reportedFormat.sampleRate); measured cadence unavailable")
            return resolvedFormat
        }

        let reportedRate = reportedFormat.sampleRate
        let shouldCorrect = abs(measuredRate - reportedRate) / max(reportedRate, 1) >= Self.correctionThresholdRatio
        let chosenRate = shouldCorrect ? measuredRate : reportedRate

        if shouldCorrect, let correctedFormat = Self.makeFormat(from: reportedFormat, sampleRate: chosenRate) {
            resolvedFormat = correctedFormat
            diagLog(
                "[SYS-TAP-RATE-DETECTED] corrected reported rate \(reportedRate) -> \(chosenRate)"
            )
        } else {
            resolvedFormat = reportedFormat
            diagLog(
                "[SYS-TAP-RATE-DETECTED] keeping reported rate \(reportedRate) " +
                "(measured cadence \(measuredRate))"
            )
        }

        return resolvedFormat
    }

    private func measuredRate() -> Double? {
        let plausibleRates = observedRates.filter { $0.isFinite && $0 >= 4_000 && $0 <= 192_000 }
        guard !plausibleRates.isEmpty else { return nil }

        let medianRate = Self.median(of: plausibleRates)
        guard let snappedRate = Self.snapToCanonicalRate(medianRate) else { return nil }
        return snappedRate
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2

        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }

        return sorted[middle]
    }

    private static func snapToCanonicalRate(_ measuredRate: Double) -> Double? {
        guard let nearestRate = canonicalRates.min(by: { abs($0 - measuredRate) < abs($1 - measuredRate) }) else {
            return nil
        }

        let tolerance = nearestRate * 0.05
        guard abs(nearestRate - measuredRate) <= tolerance else { return nil }
        return nearestRate
    }

    private static func makeFormat(from format: AVAudioFormat, sampleRate: Double) -> AVAudioFormat? {
        var streamDescription = format.streamDescription.pointee
        streamDescription.mSampleRate = sampleRate
        return AVAudioFormat(streamDescription: &streamDescription)
    }
}

private struct ResolvedDelivery {
    let format: AVAudioFormat?
    let chunks: [PendingPCMChunk]
}

private struct PendingPCMChunk: Sendable {
    let generation: UUID
    let frameCount: Int
    let bufferData: [Data]
    let capturedAt: Date

    func makePCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destinationBuffers.count == bufferData.count else { return nil }

        for index in destinationBuffers.indices {
            let byteCount = bufferData[index].count
            guard let destination = destinationBuffers[index].mData,
                  byteCount <= Int(destinationBuffers[index].mDataByteSize) else {
                return nil
            }

            bufferData[index].withUnsafeBytes { source in
                if let sourceBaseAddress = source.baseAddress {
                    memcpy(destination, sourceBaseAddress, byteCount)
                }
            }
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }

        return buffer
    }
}

private final class PCMChunkAccumulator {
    private let generation: UUID
    private let targetFrameCount: Int
    private let bytesPerFrame: Int
    private let bufferCount: Int

    private var bufferData: [Data]
    private var accumulatedFrameCount = 0
    private var chunkCapturedAt: Date?

    init(format: AVAudioFormat, targetFrameCount: Int, generation: UUID) throws {
        let streamDescription = format.streamDescription.pointee
        guard streamDescription.mBytesPerFrame > 0 else {
            throw SystemAudioCapture.CaptureError.invalidTapFormat
        }

        self.generation = generation
        self.targetFrameCount = targetFrameCount
        self.bytesPerFrame = Int(streamDescription.mBytesPerFrame)
        self.bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        self.bufferData = Array(repeating: Data(), count: bufferCount)
    }

    func append(_ inputData: UnsafePointer<AudioBufferList>, capturedAt: Date) -> PendingPCMChunk? {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard sourceBuffers.count == bufferCount else {
            reset()
            return nil
        }

        guard let frameCount = frameCount(for: sourceBuffers),
              frameCount > 0 else {
            return nil
        }

        if chunkCapturedAt == nil {
            chunkCapturedAt = capturedAt
        }

        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            let byteCount = Int(source.mDataByteSize)
            guard let sourceData = source.mData, byteCount > 0 else { continue }
            bufferData[index].append(sourceData.assumingMemoryBound(to: UInt8.self), count: byteCount)
        }

        accumulatedFrameCount += frameCount
        guard accumulatedFrameCount >= targetFrameCount else { return nil }
        return flush()
    }

    func flush() -> PendingPCMChunk? {
        guard accumulatedFrameCount > 0, let chunkCapturedAt else { return nil }
        let chunk = PendingPCMChunk(
            generation: generation,
            frameCount: accumulatedFrameCount,
            bufferData: bufferData,
            capturedAt: chunkCapturedAt
        )
        reset()
        return chunk
    }

    private func frameCount(for buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
        guard let first = buffers.first else { return nil }
        guard Int(first.mDataByteSize) % bytesPerFrame == 0 else { return nil }
        return Int(first.mDataByteSize) / bytesPerFrame
    }

    private func reset() {
        accumulatedFrameCount = 0
        bufferData = Array(repeating: Data(), count: bufferCount)
        chunkCapturedAt = nil
    }
}
