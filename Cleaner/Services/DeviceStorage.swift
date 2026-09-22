import Foundation

struct DeviceStorage: Sendable {
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// `volumeAvailableCapacityForImportantUsage` is the one that counts purgeable
    /// space the way the user experiences it. None of these APIs match Settings
    /// exactly — there is no API that does — so the UI calls the number approximate
    /// rather than pretending otherwise.
    static func read() -> DeviceStorage {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return DeviceStorage(total: 0, available: 0)
        }
        return DeviceStorage(
            total: Int64(values.volumeTotalCapacity ?? 0),
            available: values.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}

enum Fmt {
    /// Base-1000, which is what iOS Settings shows.
    static func bytes(_ n: Int64) -> String {
        guard n > 0 else { return "0 B" }
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: n)
    }

    static func count(_ n: Int) -> String { n.formatted(.number) }
}
