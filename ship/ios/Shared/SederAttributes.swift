import ActivityKit
import Foundation

/// The countdown on the Lock Screen: one block of the day.
/// Times are plain seconds since 1970 so the server can write them without any date format.
struct SederAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        /// "with Rabbi Resnick", or nothing.
        var sub: String?
        var startAt: Double
        var endAt: Double
        /// The block that comes after this one.
        var next: String?
    }

    /// Day and block, e.g. "2026-11-26:kiddushin". One countdown per block.
    var key: String
}
