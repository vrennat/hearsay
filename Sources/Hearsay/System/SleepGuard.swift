import Foundation
import HearsayCore
import IOKit
import IOKit.pwr_mgt

/// While recording: an idle-sleep assertion, and clamshell sleep off through `IOPMrootDomain`
/// (`kPMSetClamshellSleepState`, the call Amphetamine uses; no root needed). Clamshell sleep is turned
/// back on only if we turned it off; a defaults flag lets the next launch undo it after a crash.
/// The built-in mic is cut in hardware with the lid closed, so a closed lid records silence unless a
/// headset mic is in use.
final class SleepGuard {
    static let disabledClamshellKey = "sleepGuardDisabledClamshell"
    private let log = HSLog("sleep")
    private let defaults: UserDefaults
    private var assertion: IOPMAssertionID = 0
    private var holding = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func engage(reason: String) {
        if !holding {
            let st = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
            holding = st == kIOReturnSuccess
            log.info("Idle-sleep assertion \(holding ? "held" : "failed (\(st))")")
        }
        if !Distribution.current.allowsClamshellOverride {
            log.info("App Store build: idle-sleep assertion only, no clamshell override")
        } else if Self.clamshellCausesSleep() == true {
            if Self.setClamshellSleep(enabled: false) {
                defaults.set(true, forKey: Self.disabledClamshellKey)
                log.info("Clamshell sleep disabled")
            } else {
                log.error("Could not disable clamshell sleep")
            }
        } else {
            log.info("Clamshell sleep already off; leaving it")
        }
    }

    func release() {
        if holding { IOPMAssertionRelease(assertion); holding = false }
        restoreIfWeDisabled()
    }

    /// At launch: undo a clamshell change left by a crashed recording.
    func recoverAfterCrash() {
        if defaults.bool(forKey: Self.disabledClamshellKey) {
            log.info("Re-enabling clamshell sleep left off by a previous run")
            restoreIfWeDisabled()
        }
    }

    private func restoreIfWeDisabled() {
        guard defaults.bool(forKey: Self.disabledClamshellKey) else { return }
        if Self.setClamshellSleep(enabled: true) {
            defaults.removeObject(forKey: Self.disabledClamshellKey)
            log.info("Clamshell sleep re-enabled")
        } else {
            log.error("Could not re-enable clamshell sleep; will retry at next launch")
        }
    }

    private static let rootDomainPath = "IOPower:/IOPowerConnection/IOPMrootDomain"

    /// `AppleClamshellCausesSleep` from the root domain; nil if unreadable (no lid).
    static func clamshellCausesSleep() -> Bool? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, rootDomainPath)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let v = IORegistryEntryCreateCFProperty(entry, kAppleClamshellCausesSleepKey as CFString, kCFAllocatorDefault, 0)
        return v?.takeRetainedValue() as? Bool
    }

    /// `kPMSetClamshellSleepState` takes 1 to disable clamshell sleep, 0 to enable it.
    static func setClamshellSleep(enabled: Bool) -> Bool {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, rootDomainPath)
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(entry, mach_task_self_, 0, &connect) == kIOReturnSuccess else { return false }
        defer { IOServiceClose(connect) }
        var input: UInt64 = enabled ? 0 : 1
        let st = IOConnectCallMethod(connect, UInt32(kPMSetClamshellSleepState), &input, 1, nil, 0, nil, nil, nil, nil)
        return st == kIOReturnSuccess
    }
}
