import Foundation
import os

/// Read with:
///
///     log show --last 5m --predicate 'subsystem == "com.owengregson.duofold"'
///
/// Notice level, not info: info level lives only in memory, and `log show`
/// reads the on-disk store.
enum Diagnostics {
    static let geometry = Logger(subsystem: "com.owengregson.duofold", category: "geometry")
    static let lid = Logger(subsystem: "com.owengregson.duofold", category: "lid")
}
