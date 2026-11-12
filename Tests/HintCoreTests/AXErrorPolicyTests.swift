import Testing
@testable import HintCore

struct AXErrorPolicyTests {
    @Test func aTimedOutReadMeansTheAppIsUnresponsive() {
        #expect(ReadError(axError: AXErrorCode.cannotComplete) == .unresponsive)
    }

    @Test func theUnsupportedFamilyIsNotAFailureOfTheApp() {
        for code in [AXErrorCode.attributeUnsupported, AXErrorCode.parameterizedAttributeUnsupported, AXErrorCode.actionUnsupported, AXErrorCode.notImplemented] {
            #expect(ReadError(axError: code) == .unsupported)
        }
    }

    @Test func everyOtherReadErrorSkipsTheNode() {
        // kAXErrorFailure, kAXErrorIllegalArgument, kAXErrorInvalidUIElement, kAXErrorAPIDisabled, kAXErrorNoValue.
        for code: Int32 in [-25200, -25201, -25202, -25211, -25212] {
            #expect(ReadError(axError: code) == .unavailable)
        }
    }

    @Test func aPressIsDoneOnSuccessAndOnATimedOutReply() {
        #expect(ActionPlan.pressIsDone(axError: AXErrorCode.success))
        #expect(ActionPlan.pressIsDone(axError: AXErrorCode.cannotComplete), "a fallback click here could press twice")
    }

    @Test func everyOtherPressErrorFallsBackToAClick() {
        // kAXErrorFailure, kAXErrorIllegalArgument, kAXErrorInvalidUIElement, plus the unsupported family.
        for code: Int32 in [-25200, -25201, -25202, AXErrorCode.actionUnsupported, AXErrorCode.attributeUnsupported, AXErrorCode.notImplemented] {
            #expect(!ActionPlan.pressIsDone(axError: code))
        }
    }
}
