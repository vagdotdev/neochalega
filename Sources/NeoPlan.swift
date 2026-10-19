import Darwin
import Foundation

/// MacBook Neo limits. Every decision in this repo reads these numbers.
enum NeoSpec {
    static let chip = "Apple A18 Pro"
    static let memory: UInt64 = 8 * 1024 * 1024 * 1024
    static let logicalCores = 6
    static let performanceCores = 2
    static let efficiencyCores = 4
    static let gpuCores = 5
    static let bandwidthGBps = 60
    /// Machines already this close to 8 GiB are not locked further.
    static let memorySlop: UInt64 = 256 * 1024 * 1024

    static func holdBytes(hostMemory: UInt64) -> UInt64 {
        guard hostMemory > memory + memorySlop else { return 0 }
        return hostMemory - memory
    }

    static let unchanged = [
        "GPU core count. The Neo has \(gpuCores). This tool cannot disable GPU cores.",
        "Memory bandwidth. The Neo is \(bandwidthGBps) GB/s.",
        "Ports, display, and fanless thermals."
    ]
}

struct NeoPlan: Encodable {
    struct Host: Encodable {
        var chip: String
        var memoryBytes: UInt64
        var logicalCores: Int
        var performanceCores: Int
        var efficiencyCores: Int
    }

    struct Neo: Encodable {
        var chip: String
        var memoryBytes: UInt64
        var logicalCores: Int
        var performanceCores: Int
        var efficiencyCores: Int
        var gpuCores: Int
        var memoryBandwidthGbps: Int
    }

    struct Action: Encodable {
        var op: String
        var bytes: UInt64?
        var leavesBytes: UInt64?
        var cores: Int?
        var why: String
    }

    var host: Host
    var neo: Neo
    var needsChange: Bool
    var actions: [Action]
    var unchanged: [String]

    static func current() -> NeoPlan {
        let info = MachineInfo.current()
        let hold = NeoSpec.holdBytes(hostMemory: info.memory)
        var actions: [Action] = []
        if hold > 0 {
            actions.append(Action(
                op: "lock_memory",
                bytes: hold,
                leavesBytes: NeoSpec.memory,
                cores: nil,
                why: "This Mac has \(Engine.format(info.memory)). A Neo has \(Engine.format(NeoSpec.memory)). Lock the difference."
            ))
        }
        if info.ncpu > NeoSpec.logicalCores {
            actions.append(Action(
                op: "cap_parallel_cores",
                bytes: nil,
                leavesBytes: nil,
                cores: NeoSpec.logicalCores,
                why: "This Mac has \(info.ncpu) logical cores (\(info.performanceCores) performance + \(info.efficiencyCores) efficiency). A Neo has \(NeoSpec.logicalCores) (\(NeoSpec.performanceCores) performance + \(NeoSpec.efficiencyCores) efficiency). Clamp parallel work to \(NeoSpec.logicalCores). Leave a single core at full speed."
            ))
        }
        return NeoPlan(
            host: Host(
                chip: info.brand,
                memoryBytes: info.memory,
                logicalCores: info.ncpu,
                performanceCores: info.performanceCores,
                efficiencyCores: info.efficiencyCores
            ),
            neo: Neo(
                chip: NeoSpec.chip,
                memoryBytes: NeoSpec.memory,
                logicalCores: NeoSpec.logicalCores,
                performanceCores: NeoSpec.performanceCores,
                efficiencyCores: NeoSpec.efficiencyCores,
                gpuCores: NeoSpec.gpuCores,
                memoryBandwidthGbps: NeoSpec.bandwidthGBps
            ),
            needsChange: !actions.isEmpty,
            actions: actions,
            unchanged: NeoSpec.unchanged
        )
    }

    func jsonUTF8() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try? encoder.encode(self)
    }

    func jsonText() -> String {
        guard let data = jsonUTF8() else { return "{}\n" }
        return String(data: data, encoding: .utf8) ?? "{}\n"
    }
}

enum SessionLog {
    static let directory: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".neochalega")
    }()

    static var statusURL: URL { directory.appendingPathComponent("status.json") }
    static var pidURL: URL { directory.appendingPathComponent("neochalega.pid") }
    static var lockURL: URL { directory.appendingPathComponent("instance.lock") }

    static func write(phase: String, detail: String, held: UInt64, burn: Double, other: Double) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "phase": phase,
            "detail": detail,
            "held_bytes": held,
            "burn_cores": burn,
            "other_cores": other,
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: statusURL, options: .atomic)
    }

    static func read() -> String? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func snapshot() -> (phase: String, pid: Int32)? {
        guard let data = try? Data(contentsOf: statusURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = object["phase"] as? String
        else { return nil }
        guard let pidNumber = object["pid"] as? NSNumber else { return nil }
        return (phase, pidNumber.int32Value)
    }

    static func phase() -> String? {
        snapshot()?.phase
    }

    static func writePid() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: pidURL, atomically: true, encoding: .utf8)
    }

    static func clearPid() {
        try? FileManager.default.removeItem(at: pidURL)
    }

    static func runningPid() -> pid_t? {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        if kill(pid, 0) == 0 { return pid }
        return nil
    }
}

/// Holds the single-instance lock for the life of the process.
enum InstanceLock {
    private static var fd: Int32 = -1

    static func acquire() -> Bool {
        try? FileManager.default.createDirectory(at: SessionLog.directory, withIntermediateDirectories: true)
        if fd >= 0 { return true }
        let handle = open(SessionLog.lockURL.path, O_CREAT | O_RDWR, 0o644)
        if handle < 0 { return false }
        if flock(handle, LOCK_EX | LOCK_NB) != 0 {
            close(handle)
            return false
        }
        fd = handle
        return true
    }
}
