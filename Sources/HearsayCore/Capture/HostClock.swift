import Darwin

/// Mach host time, the clock AVAudioTime and Core Audio IO timestamps use. It is monotonic but does
/// NOT advance while the Mac sleeps, which is one reason recording stops on sleep: a 24-minute sleep
/// once read as a 108 s gap.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> UInt64 { mach_absolute_time() }

    public static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Signed seconds from `from` to `to`.
    public static func seconds(from: UInt64, to: UInt64) -> Double {
        to >= from ? seconds(to - from) : -seconds(from - to)
    }
}
