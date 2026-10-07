import Foundation
import CoreComponents

public enum TOSQuantumFeeProofTime {
    public static func check(master: UInt32, shard: UInt32, now: UInt32, maximumAge: UInt32, epoch0: UInt32) throws {
        guard maximumAge > 0, maximumAge < 3600, now >= epoch0 else { throw TOSPQError.invalidInput }
        let slot = (Int64(now) - Int64(epoch0)) / 3600
        for time in [master, shard] {
            guard time <= now, time >= epoch0, Int64(now) - Int64(time) <= Int64(maximumAge) else { throw TOSPQError.invalidInput }
            guard (Int64(time) - Int64(epoch0)) / 3600 == slot else { throw TOSPQError.keyBinding }
        }
    }
}
