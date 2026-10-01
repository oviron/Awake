import AwakeCore
import Darwin
import Foundation

public enum SystemClock {
    public static func now() throws -> ClockSnapshot {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            throw PolicyError.invalidClock
        }
        let seconds =
            Double(mach_continuous_time()) * Double(timebase.numer)
            / Double(timebase.denom) / 1_000_000_000
        return try ClockSnapshot(continuous: seconds, wall: Date())
    }
}
