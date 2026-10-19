import Darwin
import Foundation

final class Slot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }
    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ newValue: Int) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// In-process MacBook Neo stand-in. Memory stays locked and the core cap
/// is reapplied on a fixed tick until disarm, which frees both before it returns.
/// Nothing is forked. If this process dies, the kernel drops the lock and the threads.
final class Engine: ObservableObject {
    enum Phase: Equatable {
        case off
        case arming
        case on
        case releasing
    }

    @Published var phase: Phase = .off
    @Published var detail: String = "This Mac is at full speed."
    @Published var heldBytes: UInt64 = 0
    @Published var burnCores: Double = 0
    @Published var otherCores: Double = 0
    @Published var progress: Double = 0
    @Published var hostName: String = ""
    @Published var hostCores: Int = 0
    @Published var hostMemory: UInt64 = 0

    let targetRAM: UInt64 = NeoSpec.memory
    private let box = ThrottleBox()
    private var activity: NSObjectProtocol?

    init() {
        let info = MachineInfo.current()
        hostName = info.brand
        hostCores = info.ncpu
        hostMemory = info.memory
    }

    var isActive: Bool { phase == .on || phase == .arming || phase == .releasing }

    func toggle() {
        switch phase {
        case .off:
            phase = .arming
            progress = 0
            detail = "Locking memory…"
            beginActivity()
            SessionLog.write(phase: "arming", detail: "Locking memory…", held: 0, burn: 0, other: 0)
            box.arm(memory: hostMemory, cores: hostCores) { [weak self] event in
                DispatchQueue.main.async {
                    self?.apply(event)
                }
            }
        case .on, .arming:
            phase = .releasing
            detail = "Putting this Mac back…"
            box.requestStop()
            box.disarm { [weak self] in
                DispatchQueue.main.async {
                    self?.finishOff()
                }
            }
        case .releasing:
            break
        }
    }

    /// Blocks until the lock is gone and the burn threads have exited.
    func disarmAndWait() {
        guard phase != .off else { return }
        phase = .releasing
        let sem = DispatchSemaphore(value: 0)
        box.requestStop()
        box.disarm {
            sem.signal()
        }
        sem.wait()
        finishOff()
    }

    private func finishOff() {
        heldBytes = 0
        burnCores = 0
        otherCores = 0
        progress = 0
        phase = .off
        detail = "This Mac is at full speed."
        SessionLog.write(phase: "off", detail: detail, held: 0, burn: 0, other: 0)
        endActivity()
    }

    private func apply(_ event: ThrottleEvent) {
        switch event {
        case .progress(let done, let total):
            heldBytes = done
            progress = total == 0 ? 1 : Double(done) / Double(total)
            detail = "Locking \(Self.format(done)) of \(Self.format(total))"
            SessionLog.write(phase: "arming", detail: detail, held: done, burn: 0, other: 0)
        case .live(let held, let burn, let other):
            if phase == .releasing || phase == .off { return }
            phase = .on
            heldBytes = held
            burnCores = burn
            otherCores = other
            progress = 1
            if NeoSpec.holdBytes(hostMemory: hostMemory) == 0 {
                detail = "Memory is already 8 GB. Core cap is live."
            } else if burn < 0.25 {
                detail = "8 GB held. Under 6 cores, so one core stays fast."
            } else {
                detail = "8 GB held. Parallel work is clamped to 6 cores."
            }
            SessionLog.write(phase: "on", detail: detail, held: held, burn: burn, other: other)
        case .failed(let message):
            heldBytes = 0
            burnCores = 0
            phase = .off
            progress = 0
            detail = message
            SessionLog.write(phase: "failed", detail: message, held: 0, burn: 0, other: 0)
            endActivity()
        }
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Neochalega is holding a MacBook Neo throttle"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    static func format(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// Used by --self-test. Locks a small region, runs one burner, then proves both are gone.
    static func selfTest() -> Int {
        let cases: [(Double, Bool, Double, Double)] = [
            (0.4, false, 0, 0),
            (10, false, 0, 4),
            (6.1, true, 4, 4),
            (7.2, true, 4, 5.2),
            (4.4, true, 4, 2.4),
            (0.3, false, 4, 0),
        ]
        for (other, sat, hold, expect) in cases {
            let got = Clamp.nextBurn(other: other, saturated: sat, holding: hold, maxBurn: 8)
            if abs(got - expect) > 0.01 {
                fputs("clamp \(other) \(sat) \(hold) -> \(got), want \(expect)\n", stderr)
                return 1
            }
        }

        let box = ThrottleBox()
        let sem = DispatchSemaphore(value: 0)
        var failed: String?
        let plan = NeoPlan.current()
        guard let planData = plan.jsonUTF8(),
              (try? JSONSerialization.jsonObject(with: planData)) != nil
        else {
            fputs("self-test: plan is not json\n", stderr)
            return 1
        }
        let wantsLock = plan.actions.contains { $0.op == "lock_memory" }
        if wantsLock != (NeoSpec.holdBytes(hostMemory: plan.host.memoryBytes) > 0) {
            fputs("self-test: plan lock decision does not match NeoSpec\n", stderr)
            return 1
        }
        box.arm(memory: 8 * 1024 * 1024 * 1024 + 32 * 1024 * 1024, cores: 8, holdOverride: 32 * 1024 * 1024) { event in
            if case .failed(let message) = event { failed = message }
            if case .live = event { sem.signal() }
        }
        if sem.wait(timeout: .now() + 8) == .timedOut {
            fputs("self-test: throttle did not come live\n", stderr)
            return 1
        }
        if let failed {
            fputs("self-test: \(failed)\n", stderr)
            return 1
        }
        Thread.sleep(forTimeInterval: 0.4)
        let off = DispatchSemaphore(value: 0)
        box.disarm { off.signal() }
        if off.wait(timeout: .now() + 8) == .timedOut {
            fputs("self-test: disarm timed out\n", stderr)
            return 1
        }
        if box.lockedBytes() != 0 || box.burnerCount() != 0 {
            fputs("self-test: leftover lock=\(box.lockedBytes()) threads=\(box.burnerCount())\n", stderr)
            return 1
        }
        // A second disarm is a no-op and must not hang or resurrect the lock.
        let again = DispatchSemaphore(value: 0)
        box.disarm { again.signal() }
        again.wait()
        if box.lockedBytes() != 0 {
            fputs("self-test: lock returned\n", stderr)
            return 1
        }
        print("self-test ok")
        return 0
    }
}

enum ThrottleEvent {
    case progress(done: UInt64, total: UInt64)
    case live(held: UInt64, burn: Double, other: Double)
    case failed(String)
}

final class ThrottleBox {
    private let queue = DispatchQueue(label: "neochalega.throttle")
    private let gate = NSLock()
    private var epoch = 0
    private var regions: [(ptr: UnsafeMutableRawPointer, size: Int)] = []
    private var burners: [Burner] = []
    private var timer: DispatchSourceTimer?
    private var armed = false
    private var cancel = false
    private var holdingBurn = 0.0
    private var prevBusy: UInt32 = 0
    private var prevTotal: UInt32 = 0
    private var prevSelf: Double = 0
    private var prevWall: UInt64 = 0
    private var ncpu = 1
    private let page = Int(sysconf(_SC_PAGESIZE))

    func lockedBytes() -> UInt64 {
        queue.sync { UInt64(regions.reduce(0) { $0 + $1.size }) }
    }

    func burnerCount() -> Int {
        queue.sync { burners.count }
    }

    /// Bumps the epoch so an in-flight arm notices and bails before the queued disarm runs.
    func requestStop() {
        gate.lock()
        epoch += 1
        gate.unlock()
    }

    private func currentEpoch() -> Int {
        gate.lock()
        defer { gate.unlock() }
        return epoch
    }

    func arm(memory: UInt64, cores: Int, holdOverride: UInt64? = nil, onEvent: @escaping (ThrottleEvent) -> Void) {
        let token = currentEpoch()
        queue.async { [self] in
            guard currentEpoch() == token else { return }
            disarmOnQueue()
            cancel = false
            armed = true
            ncpu = max(1, cores)
            let hold = holdOverride ?? NeoSpec.holdBytes(hostMemory: memory)
            if hold > 0 {
                let ok = lock(hold, token: token, onEvent: onEvent)
                if !ok || currentEpoch() != token {
                    disarmOnQueue()
                    if currentEpoch() == token {
                        onEvent(.failed("Could not lock memory. Nothing was left held."))
                    }
                    return
                }
            }
            if currentEpoch() != token {
                disarmOnQueue()
                return
            }
            let extras = max(0, ncpu - NeoSpec.logicalCores)
            if extras > 0 {
                for _ in 0..<ncpu {
                    let burner = Burner()
                    burner.start()
                    burners.append(burner)
                }
            }
            prevBusy = 0
            prevTotal = 0
            prevSelf = Self.processCPU()
            prevWall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            startTimer(held: hold, onEvent: onEvent)
            onEvent(.live(held: hold, burn: 0, other: 0))
        }
    }

    func disarm(done: @escaping () -> Void) {
        queue.async { [self] in
            cancel = true
            disarmOnQueue()
            done()
        }
    }

    private func disarmOnQueue() {
        armed = false
        timer?.cancel()
        timer = nil
        for burner in burners {
            burner.stopAndJoin()
        }
        burners.removeAll()
        for region in regions {
            munlock(region.ptr, region.size)
            munmap(region.ptr, region.size)
        }
        regions.removeAll()
        holdingBurn = 0
    }

    private func lock(_ bytes: UInt64, token: Int, onEvent: (ThrottleEvent) -> Void) -> Bool {
        var left = Int(bytes)
        let chunk = 32 * 1024 * 1024
        while left > 0 {
            if currentEpoch() != token { return false }
            var n = min(chunk, left)
            n -= n % page
            if n <= 0 { break }
            guard let ptr = mmap(nil, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
                  ptr != MAP_FAILED
            else {
                return false
            }
            let raw = ptr
            var off = 0
            while off < n {
                raw.advanced(by: off).storeBytes(of: UInt8(1), as: UInt8.self)
                off += page
            }
            if mlock(raw, n) != 0 {
                munmap(raw, n)
                return false
            }
            regions.append((raw, n))
            left -= n
            onEvent(.progress(done: UInt64(regions.reduce(0) { $0 + $1.size }), total: bytes))
        }
        return left <= page
    }

    private func startTimer(held: UInt64, onEvent: @escaping (ThrottleEvent) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            self?.tick(held: held, onEvent: onEvent)
        }
        self.timer = timer
        timer.resume()
    }

    private func tick(held: UInt64, onEvent: (ThrottleEvent) -> Void) {
        guard armed else { return }
        // A dead burner is replaced on the same tick. The cap does not thin out over time.
        burners.removeAll { burner in
            if burner.isAlive { return false }
            burner.stopAndJoin()
            return true
        }
        let extras = max(0, ncpu - NeoSpec.logicalCores)
        if extras > 0 && burners.count < ncpu {
            let burner = Burner()
            burner.start()
            burners.append(burner)
        }
        for region in regions {
            mlock(region.ptr, region.size)
        }

        let sample = Self.cpuSample()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let selfCPU = Self.processCPU()
        if prevTotal == 0 {
            prevBusy = sample.busy
            prevTotal = sample.total
            prevSelf = selfCPU
            prevWall = now
            return
        }
        let db = sample.busy &- prevBusy
        let dtot = sample.total &- prevTotal
        let dself = max(0, selfCPU - prevSelf)
        let dwall = Double(now &- prevWall) / 1_000_000_000
        prevBusy = sample.busy
        prevTotal = sample.total
        prevSelf = selfCPU
        prevWall = now
        guard dtot > 0, dwall > 0.001 else { return }
        let hostCores = (Double(db) / Double(dtot)) * Double(ncpu)
        let selfCores = dself / dwall
        let other = max(0, hostCores - selfCores)
        let saturated = Double(db) / Double(dtot) > 0.90
        let maxBurn = Double(max(0, ncpu - 1))
        holdingBurn = Clamp.nextBurn(other: other, saturated: saturated, holding: holdingBurn, maxBurn: maxBurn)
        let milli = burners.isEmpty ? 0 : Int((holdingBurn / Double(burners.count)) * 1000)
        for burner in burners {
            burner.setDuty(milli)
        }
        onEvent(.live(held: UInt64(regions.reduce(0) { $0 + $1.size }), burn: holdingBurn, other: other))
        _ = held
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double {
            Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func cpuSample() -> (busy: UInt32, total: UInt32) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if kr != KERN_SUCCESS {
            return (0, 0)
        }
        let ticks = info.cpu_ticks
        let busy = ticks.0 &+ ticks.1 &+ ticks.3
        let total = busy &+ ticks.2
        return (busy, total)
    }
}

final class Burner {
    private let alive = Slot(1)
    private let duty = Slot(0)
    private var thread: Thread?

    var isAlive: Bool { thread?.isExecuting ?? false }

    func setDuty(_ milli: Int) {
        duty.set(min(1000, max(0, milli)))
    }

    func start() {
        alive.set(1)
        let alive = self.alive
        let duty = self.duty
        let thread = Thread {
            var x: UInt64 = 0x9E37_79B9_7F4A_7C15
            while alive.get() == 1 {
                let milli = duty.get()
                if milli <= 2 {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                let sliceNs: UInt64 = 50_000_000
                let burnNs = sliceNs * UInt64(milli) / 1000
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start < burnNs {
                    x = x &* 1_664_525 &+ 1_013_904_223
                    x ^= x >> 13
                }
                let rest = sliceNs > burnNs ? sliceNs - burnNs : 0
                if rest > 1_000_000 {
                    Thread.sleep(forTimeInterval: Double(rest) / 1_000_000_000)
                }
            }
            _ = x
        }
        thread.qualityOfService = .userInitiated
        thread.name = "neochalega-burn"
        thread.start()
        self.thread = thread
    }

    func stopAndJoin() {
        alive.set(0)
        duty.set(0)
        let deadline = Date().addingTimeInterval(2)
        while thread?.isExecuting == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        thread = nil
    }
}

struct MachineInfo {
    var brand: String
    var ncpu: Int
    var performanceCores: Int
    var efficiencyCores: Int
    var memory: UInt64

    static func current() -> MachineInfo {
        var mem: UInt64 = 0
        var memLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &memLen, nil, 0)
        var ncpu: Int32 = 0
        var nLen = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &nLen, nil, 0)
        let performance = sysctlInt("hw.perflevel0.logicalcpu") ?? Int(ncpu)
        let efficiency = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        var brandLen = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &brandLen, nil, 0)
        var brand = "This Mac"
        if brandLen > 0 {
            var bytes = [CChar](repeating: 0, count: brandLen)
            sysctlbyname("machdep.cpu.brand_string", &bytes, &brandLen, nil, 0)
            brand = String(cString: bytes)
        }
        return MachineInfo(
            brand: brand,
            ncpu: Int(ncpu),
            performanceCores: performance,
            efficiencyCores: efficiency,
            memory: mem
        )
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var len = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
