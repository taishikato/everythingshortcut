/// Every tunable decision of the MVP in one value.
/// The app reads `HintConfig.standard` exactly once, in `AppDelegate`, and passes it down.
/// A settings screen later replaces `.standard` with a parsed, persisted value and nothing else changes.
public struct HintConfig: Sendable {
    public var trigger: HotKey
    public var alphabet: Alphabet
    /// Wall-clock budget for one scan across all apps. Apps still traversing at the deadline
    /// return what they have. Worst-case scan time is `scanBudget + axMessagingTimeout`.
    public var scanBudget: Duration
    /// Upper bound on one AX IPC. Applied process-wide through the system-wide element.
    public var axMessagingTimeout: Duration
    public var clickPolicy: ClickPolicy
    public var roles: RoleTable
    /// Per-app cap on AX nodes read in one scan. Guards against huge trees (Preview, Mail).
    public var maxNodesPerApp: Int

    public init(
        trigger: HotKey,
        alphabet: Alphabet,
        scanBudget: Duration,
        axMessagingTimeout: Duration,
        clickPolicy: ClickPolicy,
        roles: RoleTable,
        maxNodesPerApp: Int
    ) {
        self.trigger = trigger
        self.alphabet = alphabet
        self.scanBudget = scanBudget
        self.axMessagingTimeout = axMessagingTimeout
        self.clickPolicy = clickPolicy
        self.roles = roles
        self.maxNodesPerApp = maxNodesPerApp
    }

    public static let standard = HintConfig(
        trigger: .commandShiftSpace,
        alphabet: .homeRow,
        scanBudget: .milliseconds(300),
        axMessagingTimeout: .milliseconds(150),
        clickPolicy: .pressWhenAdvertised,
        roles: .standard,
        maxNodesPerApp: 6000
    )
}
