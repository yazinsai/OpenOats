import CoreMediaIO
import Foundation

// MARK: - Camera Signal Source Protocol

/// Abstraction for observing camera activation status changes.
protocol CameraSignalSource: Sendable {
    /// Emits `true` when any camera device becomes active, `false` when all go inactive.
    var signals: AsyncStream<Bool> { get }
    /// Synchronous read of current hardware state.
    var isActive: Bool { get }
}

// MARK: - CoreMediaIO Signal Source

/// Monitors kCMIODevicePropertyDeviceIsRunningSomewhere on all video devices.
/// Does NOT capture video -- only reads activation status.
final class CoreMediaIOSignalSource: CameraSignalSource, @unchecked Sendable {
    typealias PropertyDataGetter = (
        CMIOObjectID,
        UnsafeMutablePointer<CMIOObjectPropertyAddress>,
        UInt32,
        UnsafeRawPointer?,
        UInt32,
        UnsafeMutablePointer<UInt32>,
        UnsafeMutableRawPointer
    ) -> OSStatus

    private let listenerQueue = DispatchQueue(label: "com.openoats.camera-listener")
    private var deviceIDs: [CMIOObjectID] = []
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastEmittedValue: Bool = false
    private var listenerBlocks: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var systemListenerBlock: CMIOObjectPropertyListenerBlock?

    let signals: AsyncStream<Bool>

    var isActive: Bool {
        listenerQueue.sync {
            deviceIDs.contains { Self.isDeviceRunning($0) }
        }
    }

    init() {
        var stream: AsyncStream<Bool>!
        var capturedContinuation: AsyncStream<Bool>.Continuation!

        stream = AsyncStream<Bool> { continuation in
            capturedContinuation = continuation
        }

        self.signals = stream

        listenerQueue.sync {
            self.continuation = capturedContinuation
            self.deviceIDs = Self.videoDeviceIDs()

            for deviceID in self.deviceIDs {
                self.installDeviceListener(deviceID)
            }

            self.installSystemListener()

            // Emit initial state
            let anyRunning = self.deviceIDs.contains { Self.isDeviceRunning($0) }
            self.lastEmittedValue = anyRunning
            if anyRunning {
                self.continuation?.yield(true)
            }
        }
    }

    deinit {
        for (deviceID, block) in listenerBlocks {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            CMIOObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, block)
        }
        if let block = systemListenerBlock {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, listenerQueue, block)
        }
        continuation?.finish()
    }

    // MARK: - Listener Installation

    private func installDeviceListener(_ deviceID: CMIOObjectID) {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.checkAndEmit()
        }
        listenerBlocks[deviceID] = block
        CMIOObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block)
    }

    private func installSystemListener() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChanged()
        }
        systemListenerBlock = block
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, listenerQueue, block)
    }

    // MARK: - Device List Changes (Hot-Plug)

    private func handleDeviceListChanged() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            let newDeviceIDs = Self.videoDeviceIDs()
            let oldSet = Set(self.deviceIDs)
            let newSet = Set(newDeviceIDs)

            for removed in oldSet.subtracting(newSet) {
                if let block = self.listenerBlocks.removeValue(forKey: removed) {
                    var address = CMIOObjectPropertyAddress(
                        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
                    )
                    CMIOObjectRemovePropertyListenerBlock(removed, &address, self.listenerQueue, block)
                }
            }

            for added in newSet.subtracting(oldSet) {
                self.installDeviceListener(added)
            }

            self.deviceIDs = newDeviceIDs
            self.checkAndEmitSync()
        }
    }

    // MARK: - State Check

    private func checkAndEmit() {
        listenerQueue.async { [weak self] in
            self?.checkAndEmitSync()
        }
    }

    private func checkAndEmitSync() {
        let anyRunning = deviceIDs.contains { Self.isDeviceRunning($0) }
        if anyRunning != lastEmittedValue {
            lastEmittedValue = anyRunning
            continuation?.yield(anyRunning)
        }
    }

    // MARK: - Helpers

    static func getPropertyData(
        objectID: CMIOObjectID,
        address: inout CMIOObjectPropertyAddress,
        dataSize: UInt32,
        data: UnsafeMutableRawPointer,
        getter: PropertyDataGetter = { objectID, address, qualifierDataSize, qualifierData, dataSize, dataUsed, data in
            CMIOObjectGetPropertyData(objectID, address, qualifierDataSize, qualifierData, dataSize, dataUsed, data)
        }
    ) -> (status: OSStatus, dataUsed: UInt32) {
        var dataUsed: UInt32 = 0
        let status = getter(objectID, &address, 0, nil, dataSize, &dataUsed, data)
        return (status, dataUsed)
    }

    private static func videoDeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize
        ) == kCMIOHardwareNoError else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return [] }

        // Use explicit heap allocation to avoid stack buffer overflow when
        // CoreMediaIO writes device IDs through the raw pointer.
        let buffer = UnsafeMutableBufferPointer<CMIOObjectID>.allocate(capacity: count)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0)

        let result = Self.getPropertyData(
            objectID: CMIOObjectID(kCMIOObjectSystemObject),
            address: &address,
            dataSize: dataSize,
            data: UnsafeMutableRawPointer(buffer.baseAddress!)
        )
        guard result.status == kCMIOHardwareNoError else { return [] }

        let actualCount = min(Int(result.dataUsed) / MemoryLayout<CMIOObjectID>.size, count)
        let deviceIDs = Array(buffer.prefix(actualCount))

        return deviceIDs.filter { deviceID in
            var streamAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                mScope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var streamSize: UInt32 = 0
            let status = CMIOObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
            return status == kCMIOHardwareNoError && streamSize > 0
        }
    }

    private static func isDeviceRunning(_ deviceID: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var isRunning: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let result = withUnsafeMutableBytes(of: &isRunning) { bytes in
            Self.getPropertyData(
                objectID: deviceID,
                address: &address,
                dataSize: size,
                data: bytes.baseAddress!
            )
        }
        return result.status == kCMIOHardwareNoError && isRunning != 0
    }
}
