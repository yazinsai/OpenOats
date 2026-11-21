import Foundation
@testable import OatsCapture
import OatsObjC
import Testing

@Test func shimReturnsRaisedExceptionAsError() throws {
    let error = try #require(OatsCatchException {
        NSException(name: .invalidArgumentException, reason: "required condition is false: format.sampleRate == inputHWFormat.sampleRate").raise()
    }) as NSError
    #expect(error.localizedDescription == "required condition is false: format.sampleRate == inputHWFormat.sampleRate")
    #expect(error.userInfo["name"] as? String == NSExceptionName.invalidArgumentException.rawValue)
}

@Test func shimCatchesFoundationExceptions() {
    let array = NSArray()
    #expect(OatsCatchException { _ = array.object(at: 3) } != nil)
}

@Test func shimReturnsNilWhenNothingIsRaised() {
    var ran = false
    #expect(OatsCatchException { ran = true } == nil)
    #expect(ran)
}

@Test func guardedMapsExceptionsAndErrorsToMicFailed() throws {
    #expect(try MicCapture.guarded { 42 } == 42)
    #expect {
        try MicCapture.guarded { NSException(name: .genericException, reason: "boom").raise() }
    } throws: { error in
        guard case let .micFailed(reason) = error as? CaptureError else { return false }
        return reason == "boom"
    }
    struct Failure: LocalizedError { var errorDescription: String? { "nope" } }
    #expect {
        try MicCapture.guarded { throw Failure() }
    } throws: { error in
        guard case let .micFailed(reason) = error as? CaptureError else { return false }
        return reason == "nope"
    }
}
