import CoreMediaIO
import XCTest
@testable import OpenOatsKit

final class CameraActivityMonitorTests: XCTestCase {
    func testGetPropertyDataPassesDataUsedBeforeDataBuffer() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var payload: UInt32 = 0

        let result = withUnsafeMutableBytes(of: &payload) { bytes in
            CoreMediaIOSignalSource.getPropertyData(
                objectID: CMIOObjectID(kCMIOObjectSystemObject),
                address: &address,
                dataSize: UInt32(bytes.count),
                data: bytes.baseAddress!
            ) { _, _, _, _, dataSize, dataUsed, data in
                XCTAssertEqual(dataSize, UInt32(MemoryLayout<UInt32>.size))
                XCTAssertNotNil(dataUsed)
                XCTAssertNotNil(data)

                dataUsed.pointee = dataSize
                data.assumingMemoryBound(to: UInt32.self).pointee = 0xDEADBEEF
                return OSStatus(kCMIOHardwareNoError)
            }
        }

        XCTAssertEqual(result.status, OSStatus(kCMIOHardwareNoError))
        XCTAssertEqual(result.dataUsed, UInt32(MemoryLayout<UInt32>.size))
        XCTAssertEqual(payload, 0xDEADBEEF)
    }
}
