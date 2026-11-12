/// `AXError` raw values (AXError.h) that the core's policy names. Hardcoded because the core does not
/// import ApplicationServices. The app asserts them against `AXError` at launch in DEBUG.
public enum AXErrorCode {
    public static let success: Int32 = 0
    public static let cannotComplete: Int32 = -25204
    public static let attributeUnsupported: Int32 = -25205
    public static let actionUnsupported: Int32 = -25206
    public static let notImplemented: Int32 = -25208
    public static let parameterizedAttributeUnsupported: Int32 = -25213
}

extension ReadError {
    /// The AX error boundary for reads. Every failed read the probe sees is classified here and nowhere else.
    /// - `cannotComplete` means the app did not answer in time, so the scan of that app stops.
    /// - The unsupported family means this element cannot answer this question, which is not a failure of the app.
    /// - Anything else means the element is gone or has no value, so the node is skipped.
    public init(axError code: Int32) {
        switch code {
        case AXErrorCode.cannotComplete:
            self = .unresponsive
        case AXErrorCode.attributeUnsupported, AXErrorCode.parameterizedAttributeUnsupported,
             AXErrorCode.actionUnsupported, AXErrorCode.notImplemented:
            self = .unsupported
        default:
            self = .unavailable
        }
    }
}

extension ActionPlan {
    /// Whether an `AXPress` that returned `code` counts as done.
    /// `cannotComplete` counts as done on purpose. The request reached the app and only the reply timed
    /// out, or a menu bar item blocked the reply until its menu closed, so a fallback click could press twice.
    /// Every other error means the press did nothing, so the probe clicks the fallback point.
    public static func pressIsDone(axError code: Int32) -> Bool {
        code == AXErrorCode.success || code == AXErrorCode.cannotComplete
    }
}
