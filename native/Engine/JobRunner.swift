import AVFoundation
import Darwin
import Foundation

/// Runs queued jobs one at a time. Each model runs in its own process group, so
/// cancelling or a guard releases all of its memory at once.
final class JobRunner: @unchecked Sendable {
    let library: Library
    private var paths: Paths { library.paths }
    private let queue = DispatchQueue(label: "Moonshift.jobs", qos: .userInitiated)
    private let lock = NSLock()
    private var current: (job: String, process: ChildProcess)?
    private var runningJob: String?
    /// Set when an engine could not be ejected: no other model may load beside it.
    private var cleanupError: String?
    private var working = 0
    /// The app is quitting: no new engine may start.
    private var stopping = false

    init(library: Library) {
        self.library = library
        library.onQueued = { [weak self] id in self?.enqueue(id) }
        library.onCancelled = { [weak self] id in self?.stop(id) }
        library.reclaimable = { [weak self, weak library] in
            guard let id = self?.lock.withLock({ self?.runningJob }), let job = try? library?.job(id) else { return 0 }
            return job.memory_gib ?? 0
        }
    }

    var isWorking: Bool { lock.withLock { working > 0 } }

    func enqueue(_ id: String) {
        lock.withLock { working += 1 }
        // A job queued just after Cancel waits for the cancelled engine to let go of its memory.
        if let previous = lock.withLock({ current?.job }), (try? library.job(previous))?.status == "cancelled" {
            library.update(id) { $0.stage = "Stopping the previous engine" }
        }
        queue.async { [self] in
            run(id)
            lock.withLock { working -= 1 }
        }
    }

    /// Stops the engine of a cancelled job, away from the caller's thread.
    func stop(_ id: String) {
        guard let process = lock.withLock({ current?.job == id ? current?.process : nil }) else { return }
        DispatchQueue.global().async { try? process.stop() }
    }

    /// The app is quitting: nothing it started may keep running, and nothing new starts.
    /// Blocks until the engine is gone, so call it away from the main thread.
    func shutdown() {
        lock.withLock { stopping = true }
        for job in library.jobs where job.active {
            library.update(job.id, status: "cancelled") {
                $0.stage = "Cancelled"; $0.error = "Stopped when Moonshift quit."; $0.finished_at = timestamp()
            }
        }
        if let process = lock.withLock({ current?.process }) { try? process.stop() }
    }

    /// Stops engines a crash left running, before any job may load another model beside them.
    func eject(_ engines: [(pid: pid_t, started: UInt64)]) {
        guard !engines.isEmpty else { return }
        queue.async { [self] in
            for engine in engines where Machine.startTime(engine.pid) == engine.started && getpgid(engine.pid) == engine.pid {
                do {
                    try Machine.stopGroup(engine.pid)
                } catch {
                    lock.withLock { cleanupError = error.localizedDescription }
                }
            }
        }
    }

    // MARK: One job

    private func run(_ id: String) {
        guard let lease = acquireEngineLock(id) else { return }
        defer { flock(lease, LOCK_UN); close(lease) }
        lock.withLock { runningJob = id }
        defer { lock.withLock { runningJob = nil } }
        do {
            let job = try library.job(id)
            guard job.status == "queued" else { return }
            if let cleanupError = lock.withLock({ cleanupError }) { throw ServiceError(cleanupError) }
            let kind = job.request.kind
            let forecast = library.estimator.estimate(job.request.project, kind: kind, memory: library.memory())
            guard forecast.allowed else { throw ServiceError(forecast.reason) }
            // Recheck after queueing; another application may have used memory.
            let limit = min(forecast.memory.limit_gib, forecast.memory.available_gib - forecast.memory.reserve_gib)
            var request = job.request
            request.project.engine = forecast.engine
            library.update(id, status: "running") {
                $0.request = request; $0.estimate = forecast; $0.memory_limit_gib = (limit * 100).rounded() / 100
                $0.stage = "Loading engine"; $0.started_at = timestamp()
            }
            let log = FileHandle.create(library.folder(of: id).appendingPathComponent("worker.log"))
            defer { try? log?.close() }
            let result = kind == "transcribe"
                ? try transcribe(id, request: request, limit: limit, log: log)
                : try MusicRender(runner: self, id: id, request: request, limit: limit, log: log).run()
            library.update(id, status: "complete") { $0.stage = "Complete"; $0.result = result; $0.finished_at = timestamp() }
        } catch {
            if let job = try? library.job(id), job.active {
                library.update(id, status: "failed") { $0.stage = "Failed"; $0.error = error.localizedDescription; $0.finished_at = timestamp() }
            }
        }
    }

    /// Serializes model work across Moonwire and Moonshift, which share this lock.
    func acquireEngineLock(_ id: String) -> Int32? {
        try? FileManager.default.createDirectory(at: paths.engineLock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(paths.engineLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            library.update(id, status: "failed") { $0.stage = "Failed"; $0.error = "The engine lock could not be opened."; $0.finished_at = timestamp() }
            return nil
        }
        var waiting = false
        while (try? library.job(id))?.status == "queued" {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
            if !waiting {
                library.update(id) { $0.stage = "Waiting for another local music job" }
                waiting = true
            }
            usleep(500_000)
        }
        close(descriptor)
        return nil
    }

    // MARK: Engine processes

    /// Starts a model process for a job, with the memory guard and, for the
    /// music engine, the progress guard watching it. Throws when it fails.
    func launch(_ id: String, _ executable: URL, _ arguments: [String], limit: Double, watchProgress: Bool,
                log: FileHandle?, onLine: (String, () -> Void) -> Void) throws -> Int32 {
        // Checked under the same lock `shutdown` sets, so quitting between two engines starts neither.
        let process: ChildProcess = try lock.withLock {
            guard !stopping, (try? library.job(id))?.active == true else { throw CancellationError() }
            let process = try ChildProcess.spawn(executable.path, arguments, environment: paths.environment, directory: paths.code)
            current = (id, process)
            return process
        }
        defer { lock.withLock { current = nil } }
        let started = Machine.startTime(process.pid)
        library.update(id) { $0.engine_pid = process.pid; $0.engine_started = started }
        defer { library.update(id) { $0.engine_pid = nil; $0.engine_started = nil } }
        let heartbeat = Heartbeat()
        let monitor = Thread { [self] in watch(id, process, limit: limit, progress: watchProgress ? heartbeat : nil) }
        monitor.start()
        defer { monitor.cancel() }
        process.readLines { line in
            log?.write(Data((line + "\n").utf8))
            // Any output shows the engine is alive: loading and decoding report little else.
            heartbeat.beat()
            onLine(line) {}
        }
        let code = process.wait()
        do {
            try process.stop()
        } catch {
            // Do not load another model if ejection cannot be confirmed.
            lock.withLock { cleanupError = error.localizedDescription }
            library.update(id, status: "failed") { $0.stage = "Engine cleanup failed"; $0.error = error.localizedDescription; $0.finished_at = timestamp() }
            throw error
        }
        return code
    }

    final class Heartbeat: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var beats = 0
        func beat() { lock.withLock { last = Date(); beats += 1 } }
        var silence: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
        /// How long silence may last: loading a model from a slow disk says nothing for a while.
        var allowance: TimeInterval { lock.withLock { beats == 0 ? 600 : 180 } }
    }

    /// The live guards: memory twice a second, and progress for the music engine.
    private func watch(_ id: String, _ process: ChildProcess, limit: Double, progress: Heartbeat?) {
        var guardian = MemoryGuard(limit: limit)
        var reported: (gib: Double, at: Date)?
        while !Thread.current.isCancelled && !process.exited {
            Thread.sleep(forTimeInterval: 0.5)
            guard !Thread.current.isCancelled, !process.exited else { return }
            let used = Machine.groupFootprint(process.pid)
            let verdict = guardian.check(used: used, memory: library.memory(), silence: progress?.silence, allowance: progress?.allowance ?? 180)
            // The guard samples twice a second; the job only needs visible changes.
            if verdict != nil || reported == nil || abs(used - reported!.gib) >= 0.1 || Date().timeIntervalSince(reported!.at) > 5 {
                library.update(id, live: true) {
                    $0.memory_gib = (used * 100).rounded() / 100; $0.peak_memory_gib = (guardian.peak * 100).rounded() / 100
                    $0.memory_limit_gib = (limit * 100).rounded() / 100
                }
                reported = (used, Date())
            }
            if let verdict {
                library.update(id, status: "failed") { $0.stage = verdict.stage; $0.error = verdict.message; $0.finished_at = timestamp() }
                try? process.stop()
                return
            }
        }
    }

    // MARK: Transcription

    /// SheetSage2 runs in its own Python environment; it reports progress as `STUDIO_EVENT` lines.
    private func transcribe(_ id: String, request: JobRequest, limit: Double, log: FileHandle?) throws -> JobResult {
        let folder = library.folder(of: id)
        guard FileManager.default.isExecutableFile(atPath: paths.coversPython.path) else {
            throw ServiceError("The local engines are not installed yet. Install them in Settings.")
        }
        try FileManager.default.createDirectory(at: paths.temporary, withIntermediateDirectories: true)
        let code = try launch(id, paths.coversPython, ["-m", "studio.covers", folder.path], limit: limit, watchProgress: false, log: log) { line, beat in
            guard line.hasPrefix("STUDIO_EVENT "), let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(13).utf8)) as? [String: Any] else { return }
            beat()
            apply(event, to: id)
        }
        guard (try? library.job(id))?.active == true else { throw CancellationError() }
        let output = folder.appendingPathComponent("output.json")
        if code == 0, let data = FileManager.default.contents(atPath: output.path) {
            return try JSONDecoder().decode(JobResult.self, from: data)
        }
        let failure = FileManager.default.contents(atPath: folder.appendingPathComponent("error.json").path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
        throw ServiceError(failure ?? "The engine exited unexpectedly.")
    }

    /// Progress the transcription helper reports.
    private func apply(_ event: [String: Any], to id: String) {
        library.update(id, live: true) { job in
            if let stage = event["stage"] as? String { job.stage = stage }
            if let phase = event["phase"] as? String { job.phase = phase }
            if event.keys.contains("progress") { job.progress = event["progress"] as? Double }
            if let tokens = event["tokens"] as? Int { job.tokens = tokens }
        }
    }
}

/// Stops a job that is about to take more memory than the Mac can give, or a
/// music engine that has stopped making progress.
struct MemoryGuard {
    var limit: Double
    var peak = 0.0
    var pressure = 0

    init(limit: Double) { self.limit = limit }

    mutating func check(used: Double, memory: MemoryState, silence: TimeInterval?, allowance: TimeInterval = 180) -> (stage: String, message: String)? {
        peak = max(peak, used)
        pressure = Self.strained(memory) ? pressure + 1 : 0
        if used > limit || pressure >= 3 {
            return ("Memory guard", String(format: "Memory guard stopped this job at %.1f GB (limit %.1f GB, %.1f GB available). Try 4-bit, a shorter length, or close other heavy apps.",
                                           used, limit, memory.available_gib))
        }
        if let silence, silence > allowance {
            return ("Progress guard", "The music engine made no progress for three minutes and was stopped. The song it wrote is saved: resume rendering in sections to finish it.")
        }
        return nil
    }

    /// The Mac is about to start swapping hard. Free plus inactive memory undercounts
    /// what macOS can reclaim (a mapped model's pages, for one), so the kernel's own
    /// pressure level decides when it is known, with a hard floor beneath it.
    static func strained(_ memory: MemoryState) -> Bool {
        guard let level = memory.pressure else { return memory.available_gib < 3 }
        return level >= 4 || (level >= 2 && memory.available_gib < 3) || memory.available_gib < 1.5
    }
}

extension FileHandle {
    static func create(_ url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }
}
