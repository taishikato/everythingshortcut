/// Every tunable decision in one value.
/// `AppDelegate` builds it once as `HintConfig.standard.applying(SettingsStore.load())` and passes it down.
/// The user edits only `settings` (trigger and alphabet), and the reducer applies a change only while idle.
public struct HintConfig: Sendable {
    public var trigger: HotKey
    public var alphabet: Alphabet
    /// Wall-clock budget for one scan across all apps. Apps still traversing at the deadline
    /// return what they have. Worst-case scan time is `scanBudget + axMessagingTimeout`.
    public var scanBudget: Duration
    /// Upper bound on one AX IPC. Applied process-wide through the system-wide element.
    public var axMessagingTimeout: Duration
    /// Upper bound on one AX IPC for extras-only jobs, set on that app's element. Extras matter less
    /// than windows, and about 71 apps may own one, so a hung app costs its lane less (Vimac uses 50 ms).
    public var extrasMessagingTimeout: Duration
    public var clickPolicy: ClickPolicy
    /// After raising a background window, how long a click waits for its app to report frontmost,
    /// so the click lands on an active window instead of only activating it.
    public var frontmostWait: Duration
    public var roles: RoleTable
    /// Per-app cap on AX nodes read in one scan. Guards against huge trees (Preview, Mail).
    public var maxNodesPerApp: Int

    public init(
        trigger: HotKey,
        alphabet: Alphabet,
        scanBudget: Duration,
        axMessagingTimeout: Duration,
        extrasMessagingTimeout: Duration,
        clickPolicy: ClickPolicy,
        frontmostWait: Duration,
        roles: RoleTable,
        maxNodesPerApp: Int
    ) {
        self.trigger = trigger
        self.alphabet = alphabet
        self.scanBudget = scanBudget
        self.axMessagingTimeout = axMessagingTimeout
        self.extrasMessagingTimeout = extrasMessagingTimeout
        self.clickPolicy = clickPolicy
        self.frontmostWait = frontmostWait
        self.roles = roles
        self.maxNodesPerApp = maxNodesPerApp
    }

    public static let standard = HintConfig(
        trigger: .commandShiftSpace,
        alphabet: .homeRow,
        scanBudget: .milliseconds(300),
        axMessagingTimeout: .milliseconds(150),
        extrasMessagingTimeout: .milliseconds(50),
        clickPolicy: .pressWhenAdvertised,
        frontmostWait: .milliseconds(150),
        roles: .standard,
        maxNodesPerApp: 6000
    )
}
