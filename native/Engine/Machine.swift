import Darwin
import Foundation

/// Memory, cores and processes: what the job runner needs to know about this Mac.
enum Machine {
    static let gib = 1024.0 * 1024 * 1024

    /// Free memory the way Activity Monitor's pressure sees it, and the limits a render plans within.
    static func memory() -> MemoryState {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / gib
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var free = 0.0, available = 0.0
        if status == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            free = Double(Int64(statistics.free_count) - Int64(statistics.speculative_count)) * page / gib
            available = free + Double(statistics.inactive_count) * page / gib
        }
        func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        return MemoryState(total_gib: rounded(total), available_gib: rounded(available), free_gib: rounded(free),
                           limit_gib: rounded(min(24, total * 0.60)), reserve_gib: min(6.0, total * 0.17))
    }

    /// Engine threads belong on performance cores; efficiency cores slow them down.
    static var performanceCores: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) != 0 || count <= 0 {
            count = Int32(ProcessInfo.processInfo.processorCount / 2)
        }
        return max(4, min(12, Int(count)))
    }

    /// The Darwin ledger footprint, which counts compressed pages, unlike RSS.
    static func footprint(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    static func allProcesses() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 64))
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, found)))).filter { $0 > 0 }
    }

    static func isZombie(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status == SZOMB
    }

    /// Live members of a process group: an engine and anything it started.
    static func group(_ leader: pid_t) -> [pid_t] {
        allProcesses().filter { getpgid($0) == leader && !isZombie($0) }
    }

    /// Memory held by a whole process group, in GiB.
    static func groupFootprint(_ leader: pid_t) -> Double {
        Double(group(leader).compactMap(footprint).reduce(0, +)) / gib
    }
}

/// A process started in a process group of its own, so stopping it stops
/// everything it started too, and its output read line by line.
final class ChildProcess: @unchecked Sendable {
    let pid: pid_t
    private let output: FileHandle
    private let lock = NSLock()
    private var exitStatus: Int32?

    private init(pid: pid_t, output: FileHandle) { self.pid = pid; self.output = output }

    static func spawn(_ executable: String, _ arguments: [String], environment: [String: String], directory: URL? = nil) throws -> ChildProcess {
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { throw ServiceError("The engine could not be started.") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own group, and nothing of the app's open files: the engine lock above all.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var signals = sigset_t()
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(pipe[1])
        guard status == 0 else {
            close(pipe[0])
            throw ServiceError("The engine could not be started: \(String(cString: strerror(status))).")
        }
        return ChildProcess(pid: pid, output: FileHandle(fileDescriptor: pipe[0], closeOnDealloc: true))
    }

    /// Calls `handle` with each line of output until the process closes it.
    func readLines(_ handle: (String) -> Void) {
        var pending = Data()
        while true {
            let chunk = output.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                handle(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...end)
            }
        }
        if !pending.isEmpty { handle(String(decoding: pending, as: UTF8.self)) }
    }

    /// Waits for the process and returns its exit status. Only the thread that reads it calls this.
    @discardableResult func wait() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        lock.withLock { exitStatus = code }
        return code
    }

    var exited: Bool { lock.withLock { exitStatus != nil } }

    /// Stops the whole group, escalating if the GPU driver ignores termination.
    /// Throws when something in it survives, so no second model is ever loaded beside it.
    func stop() throws {
        guard !Machine.group(pid).isEmpty else { return }
        killpg(pid, SIGTERM)
        for _ in 0..<30 where !Machine.group(pid).isEmpty { usleep(100_000) }
        killpg(pid, SIGKILL)
        for _ in 0..<50 where !Machine.group(pid).isEmpty { usleep(100_000) }
        if !Machine.group(pid).isEmpty {
            throw ServiceError("A previous engine could not be ejected. Quit Moonshift before starting another model.")
        }
    }
}
