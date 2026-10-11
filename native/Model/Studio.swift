import AppKit
import Observation

/// The app's state: the open cover, the library, running jobs, and the local service.
@MainActor @Observable final class Studio {
    enum Phase: Equatable {
        case starting
        /// macOS has not let the app into its own folder yet.
        case needsAccess
        /// Nothing is installed; only setup can run.
        case needsSetup
        case offline(String)
        case ready
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
    }

    let service = Service()
    let player = Player()
    let presets: PresetStore
    let installer: Installer

    private(set) var phase = Phase.starting
    var showsOnboarding = false
    /// Onboarding has moved on from the welcome to installing.
    var onboardingSetup = false
    /// The cover being edited. Changes save themselves.
    var project = Project() { didSet { projectDidChange(from: oldValue) } }
    private(set) var projects: [Project] = []
    private(set) var jobs: [Job] = []
    private(set) var health: Health?
    private(set) var estimate: RenderEstimate?
    var step = CoverStep.song
    var notice: Notice?
    var importing = false
    private(set) var submitting = false
    /// Takes that finished since the app opened and have not been played.
    private(set) var unheard: Set<String> = []

    // Song details and optional online lookup, for the open cover.
    var onlineLookup = false {
        didSet { UserDefaults.standard.set(onlineLookup, forKey: "CoverOnlineLookup") }
    }
    var songDuration = 0.0
    var lookupBusy = false
    var lookupMessage = ""
    var candidates: [LyricCandidate] = []
    var reviewing: LyricCandidate?
    @ObservationIgnored var lookupToken = UUID()

    /// Covers waiting for their transcription, keyed by that job.
    private var chains: [String: Project] = [:]
    @ObservationIgnored private var saved = Project()
    @ObservationIgnored private var advancing: Set<String> = []
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<Bool, Never>?
    @ObservationIgnored private var estimating: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var settled: Set<String>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var folderAccess: URL?
    #if SNAPSHOT
    @ObservationIgnored private var rehearsed = false
    #endif

    init() {
        Self.adoptEarlierSettings()
        presets = PresetStore()
        installer = Installer(root: service.root, scripts: service.code.appendingPathComponent("scripts"), helpers: service.isPackaged ? service.helpers : nil)
        onlineLookup = UserDefaults.standard.bool(forKey: "CoverOnlineLookup")
        let fresh = newProject()
        saved = fresh
        project = fresh
    }

    /// Builds before 1.0 kept presets and preferences under other identifiers.
    private static func adoptEarlierSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "AdoptedEarlierSettings") else { return }
        for domain in ["local.yue.moonshift", "local.yue.covers"] {
            let earlier = defaults.persistentDomain(forName: domain) ?? [:]
            for key in ["CoverStylePresets", "CoverPreferredEngine", "CoverOnlineLookup", "StudioFolderBookmark"] where defaults.object(forKey: key) == nil {
                if let value = earlier[key] { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: "AdoptedEarlierSettings")
    }

    // MARK: Derived state

    var isReady: Bool { phase == .ready }
    var hasContent: Bool { project.hasContent }
    var currentJobs: [Job] { project.id.isEmpty ? [] : jobs.filter { $0.request.project.id == project.id } }
    var activeJob: Job? { currentJobs.first(where: \.active) }
    /// Any cover being created, open or not.
    var runningJob: Job? { jobs.last(where: \.active) }
    /// Editing pauses while this cover is being created, so the take matches what you see.
    var locked: Bool { submitting || importing || activeJob != nil || chains.values.contains { $0.id == project.id } }
    var takes: [Job] { currentJobs.filter { $0.isGeneration && !$0.tracks.isEmpty } }
    /// A stopped or failed attempt worth showing: the most recent job, if it did not finish.
    var setback: Job? {
        guard let latest = currentJobs.first, ["failed", "cancelled"].contains(latest.status) else { return nil }
        return latest
    }
    var selectedPreset: CoverPreset? { presets.preset(matching: project) }
    var modelsReady: Bool { health?.transcriptionReady == true && health?.ready(project.quality) == true }
    var canCreate: Bool {
        isReady && modelsReady && project.hasSong && project.hasWords && project.hasStyle && !locked && estimate?.allowed != false
    }

    func isBusy(_ id: String) -> Bool {
        !id.isEmpty && (jobs.contains { $0.active && $0.request.project.id == id } || chains.values.contains { $0.id == id })
    }

    func takeCount(_ id: String) -> Int {
        jobs.reduce(0) { $0 + ($1.isGeneration && $1.request.project.id == id ? $1.tracks.count : 0) }
    }

    /// A finished transcription of this recording. Covers of the same song share it.
    func transcription(of source: String) -> Job? {
        jobs.first { $0.isTranscription && $0.status == "complete" && $0.request.source == source && !source.isEmpty }
    }

    func newProject() -> Project {
        var project = Project()
        let preset = presets.presets[0]
        project.style = preset.style; project.voice = preset.voice; project.vocal_prompt = preset.vocal
        project.cover_preset = preset.name
        project.engine = Quality.preferred.rawValue
        return project
    }

    // MARK: Startup

    func start() async {
        // Coming from setup, the onboarding screen stays up while the service starts.
        if phase != .needsSetup { phase = .starting }
        #if SNAPSHOT
        // Screenshots can be taken against a service started by hand, before
        // macOS has been asked to let this build into the folder.
        let attached = ProcessInfo.processInfo.environment["MOONSHIFT_SNAPSHOT_ATTACH"] != nil
        #else
        let attached = false
        #endif
        if !attached, !(await authorizeFolder()) { phase = .needsAccess; return }
        #if SNAPSHOT
        // Pretends nothing is installed on the first start, to rehearse a first run.
        let rehearsal = ProcessInfo.processInfo.environment["MOONSHIFT_SNAPSHOT_FRESH"] != nil && !rehearsed
        rehearsed = true
        #else
        let rehearsal = false
        #endif
        guard !rehearsal, attached || service.isInstalled else {
            showsOnboarding = true
            phase = .needsSetup
            return
        }
        do {
            health = try await service.connect()
        } catch {
            phase = .offline(error.localizedDescription)
            return
        }
        phase = .ready
        failures = 0
        await refresh()
        if !hasContent, let recent = projects.first { load(recent) }
        if health?.canCreate == true {
            UserDefaults.standard.set(true, forKey: "OnboardingComplete")
        } else if !UserDefaults.standard.bool(forKey: "OnboardingComplete") {
            showsOnboarding = true
        }
        polling?.cancel()
        polling = Task { [weak self] in await self?.poll() }
        await refreshEstimate()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "OnboardingComplete")
        showsOnboarding = false
        onboardingSetup = false
        installer.reset()
    }

    /// Lets the user keep models and covers on another disk, before anything is installed.
    func chooseLibraryFolder() {
        guard service.isPackaged, phase == .needsSetup, !installer.running else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose where Moonshift keeps its models and your covers. It makes a Moonshift folder there."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let folder = parent.lastPathComponent == "Moonshift" ? parent : parent.appendingPathComponent("Moonshift")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            report(error, title: "Moonshift cannot use that folder")
            return
        }
        // The panel's grant covers this launch; the bookmark covers later ones.
        rememberFolder(folder)
        service.relocate(to: folder)
        installer.root = folder
    }

    /// Setup finished: start the service if this was the first install, and see what is now available.
    func installFinished() async {
        if isReady {
            await refreshHealth()
            await refreshEstimate()
        } else {
            await start()
        }
    }

    /// The service and models live in the project folder. macOS may ask the user
    /// before letting the app into it; that question must not freeze the window.
    private func authorizeFolder() async -> Bool {
        let root = service.root
        if let bookmark = UserDefaults.standard.data(forKey: "StudioFolderBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               url.path == root.path, !stale, url.startAccessingSecurityScopedResource() {
                folderAccess = url
                return true
            }
        }
        let readable = await Task.detached { (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil }.value
        if readable { rememberFolder(root) }
        return readable
    }

    /// Lets later launches, and rebuilt copies of the app, back in without asking again.
    private func rememberFolder(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "StudioFolderBookmark")
        }
    }

    /// Asks for the project folder, for disks macOS guards.
    func grantFolderAccess() async {
        let root = service.root
        let panel = NSOpenPanel()
        panel.message = "Moonshift keeps its models and your covers in this folder. Choose it to allow access."
        panel.prompt = "Allow Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.path == root.path else {
            notice = Notice(title: "That is a different folder", message: "Choose \(root.path), where this copy of Moonshift lives.")
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        folderAccess = url
        rememberFolder(url)
        await start()
    }

    func shutdown() async {
        polling?.cancel()
        autosave?.cancel()
        player.pause()
        installer.cancel()
        if isReady {
            await save()
            await service.disconnect()
        }
        folderAccess?.stopAccessingSecurityScopedResource()
    }

    // MARK: Staying in sync

    private func poll() async {
        var tick = 0
        while !Task.isCancelled {
            // Quick while a cover is being made; unhurried otherwise.
            let pause: Duration = jobs.contains(where: \.active) ? .milliseconds(700) : NSApp.isActive ? .milliseconds(2500) : .seconds(6)
            try? await Task.sleep(for: pause)
            if Task.isCancelled { return }
            await refresh()
            tick += 1
            if tick % 4 == 0 { await refreshHealth() }
            // Free memory moves with whatever else is open.
            if step == .create, tick % 2 == 0, NSApp.isActive { await refreshEstimate() }
        }
    }

    func refresh() async {
        guard isReady else { return }
        do {
            if let state = try await service.state() { apply(state) }
            failures = 0
        } catch {
            failures += 1
            if failures == 3 { await reconnect() }
        }
    }

    private func reconnect() async {
        do {
            health = try await service.connect()
            failures = 0
        } catch {
            polling?.cancel()
            phase = .offline(error.localizedDescription)
        }
    }

    func refreshHealth() async {
        guard isReady, let value: Health = try? await service.get("health"), value != health else { return }
        health = value
    }

    private func apply(_ state: ServiceState) {
        let covers = state.projects.elements.filter { $0.app_mode == "covers" }
        if covers != projects { projects = covers }
        guard state.jobs.elements != jobs else { return }
        jobs = state.jobs.elements

        let finished = Set(jobs.filter { !$0.active }.map(\.id))
        if let settled {
            for job in jobs where finished.contains(job.id) && !settled.contains(job.id) && job.isGeneration {
                if job.status == "complete" { unheard.formUnion(job.tracks.map(\.id)) }
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
        settled = finished
        advanceChains()

        // Keep the Mac awake, and the app out of App Nap, while a cover is made.
        let working = jobs.contains(where: \.active)
        if working, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Creating a cover")
        } else if !working, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    // MARK: Editing and saving

    private var isDirty: Bool { project.content != saved.content }

    private func projectDidChange(from old: Project) {
        guard project != old else { return }
        if isDirty { scheduleSave() }
        if project.content != old.content { scheduleEstimate() }
    }

    private func scheduleSave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.autosave = nil
            await self.save()
        }
    }

    private func scheduleEstimate() {
        estimating?.cancel()
        estimating = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refreshEstimate()
        }
    }

    func refreshEstimate() async {
        guard isReady else { return }
        let asked = project
        guard let value: RenderEstimate = try? await service.post("estimate", asked), project.content == asked.content else { return }
        if value != estimate { estimate = value }
    }

    /// Writes the open cover if it changed. An untouched new cover is never stored.
    @discardableResult func save() async -> Bool {
        if let saving { _ = await saving.value }
        guard isReady, isDirty, project.hasContent || !project.id.isEmpty else { return true }
        let sent = project
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            do {
                let stored: Project = try await self.service.post("projects", sent)
                self.saved = sent
                self.saved.id = stored.id; self.saved.updated_at = stored.updated_at
                if self.project.id == sent.id {
                    self.project.id = stored.id; self.project.updated_at = stored.updated_at
                }
                self.remember(stored)
                return true
            } catch {
                self.report(error, title: "This cover could not be saved")
                return false
            }
        }
        saving = task
        let result = await task.value
        saving = nil
        return result
    }

    /// Reflects a saved cover in the library without waiting for the next poll.
    private func remember(_ stored: Project) {
        projects.removeAll { $0.id == stored.id }
        projects.insert(stored, at: 0)
    }

    private func load(_ target: Project) {
        resetLookup()
        saved = target
        project = target
        estimate = nil
        step = takeCount(target.id) > 0 || isBusy(target.id) ? .create : .song
        Task {
            await loadSongDetails()
            await refreshEstimate()
        }
    }

    func open(_ target: Project) async {
        guard target.id != project.id, await save() else { return }
        load(target)
    }

    func newCover() async {
        guard await save() else { return }
        load(newProject())
    }

    func rename(_ target: Project, to title: String) async {
        let title = String(title.trimmed.prefix(160))
        guard !title.isEmpty, title != target.title else { return }
        if target.id == project.id {
            project.title = title
            await save()
            return
        }
        var renamed = target
        renamed.title = title
        do {
            let stored: Project = try await service.post("projects", renamed)
            if let index = projects.firstIndex(where: { $0.id == stored.id }) { projects[index] = stored }
        } catch {
            report(error, title: "This cover could not be renamed")
        }
    }

    /// The same song and words, ready for a different sound.
    func duplicate(_ source: Project) async {
        guard await save() else { return }
        var copy = source.id == project.id ? project : source
        copy.id = ""; copy.updated_at = ""
        copy.title = String((copy.title + " copy").prefix(160))
        load(copy)
        step = .style
        scheduleSave()
    }

    func delete(_ target: Project) async {
        guard !target.id.isEmpty else { return }
        if jobs.contains(where: { $0.request.project.id == target.id && $0.tracks.contains { $0.audio == player.source } }) || player.source == target.cover_source {
            player.stop()
        }
        do {
            if target.id == project.id { autosave?.cancel(); saved = project }
            try await service.send("DELETE", "projects/\(target.id)")
            projects.removeAll { $0.id == target.id }
            if target.id == project.id { load(projects.first ?? newProject()) }
            await refresh()
        } catch {
            report(error, title: "This cover could not be deleted")
        }
    }

    func report(_ error: Error, title: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        notice = Notice(title: title, message: error.localizedDescription)
    }

    // MARK: Creating

    func createCover() async {
        guard canCreate else { return }
        submitting = true
        defer { submitting = false }
        // A new seed for each take; otherwise identical settings repeat the same performance.
        project.seed = Int.random(in: 1..<2_000_000_000)
        guard await save() else { return }
        let snapshot = project
        if let transcription = transcription(of: snapshot.cover_source) {
            await generate(snapshot, from: transcription)
        } else if let job = await submit(JobRequest(kind: "transcribe", project: snapshot, source: snapshot.cover_source)) {
            chains[job.id] = snapshot
        }
    }

    private func advanceChains() {
        for (id, snapshot) in chains {
            guard let job = jobs.first(where: { $0.id == id }) else { chains[id] = nil; continue }
            guard !job.active else { continue }
            if job.status == "complete" {
                // The cover stays locked until its music job is queued.
                guard advancing.insert(id).inserted else { continue }
                Task {
                    await generate(snapshot, from: job)
                    chains[id] = nil
                    advancing.remove(id)
                }
            } else {
                chains[id] = nil
            }
        }
    }

    /// Queues the music job with the score heard in the reference song.
    private func generate(_ snapshot: Project, from transcription: Job, resuming: Job? = nil) async {
        var cover = snapshot
        guard let score = cover.keepsHarmony ? transcription.result.full_abc : transcription.result.abc, !score.isEmpty else {
            notice = Notice(title: "No melody was found", message: "Moonshift could not hear a usable melody in this recording. Try a clearer recording of the song.")
            return
        }
        cover.abc = score
        cover.cover_job = transcription.id
        if cover.id == project.id {
            // The saved cover records which score it was made from.
            project.abc = score
            project.cover_job = transcription.id
            guard await save() else { return }
        }
        await submit(JobRequest(kind: "generate", project: cover, resumeFrom: resuming?.id ?? ""))
    }

    @discardableResult private func submit(_ request: JobRequest) async -> Job? {
        do {
            let job: Job = try await service.post("jobs", request)
            await refresh()
            return job
        } catch {
            report(error, title: request.kind == "transcribe" ? "Moonshift could not start listening" : "This cover could not be started")
            return nil
        }
    }

    /// Renders audio from the song a stopped job already wrote, optionally in
    /// sections, which is steadier on long songs.
    func resume(_ job: Job, inSections: Bool) async {
        guard job.resumable, !isBusy(job.request.project.id) else { return }
        var cover = job.request.project
        cover.takes = 1
        if inSections { cover.nar_chunk_frames = 1024 }
        do {
            let _: Job = try await service.post("jobs", JobRequest(kind: "generate", project: cover, resumeFrom: job.id))
            await refresh()
        } catch {
            report(error, title: "Rendering could not resume")
        }
    }

    func cancel(_ job: Job) async {
        chains[job.id] = nil
        do {
            try await service.send("POST", "jobs/\(job.id)/cancel")
            await refresh()
        } catch {
            report(error, title: "This job could not be cancelled")
        }
    }

    func delete(_ job: Job) async {
        if job.tracks.contains(where: { $0.audio == player.source }) { player.stop() }
        do {
            try await service.send("DELETE", "jobs/\(job.id)")
            await refresh()
        } catch {
            report(error, title: "This take could not be deleted")
        }
    }

    /// Brings a take's style and singer back into the editor.
    func reuseSettings(of job: Job) {
        let source = job.request.project
        project.style = source.style; project.voice = source.voice; project.vocal_prompt = source.vocal_prompt
        project.cover_preset = source.cover_preset; project.cot = source.cot; project.language = source.language; project.tempo = source.tempo
        step = .style
    }

    // MARK: Listening

    func toggle(_ track: AudioTrack, title: String) {
        unheard.remove(track.id)
        if player.source == track.audio { player.toggle(); return }
        do {
            try player.load(service.file(track.audio), source: track.audio, title: title, waveform: track.waveform)
            player.play()
        } catch {
            report(error, title: "This recording could not be played")
        }
    }

    func toggleReference() {
        guard project.hasSong else { return }
        let reference = AudioTrack(name: "Original", audio: project.cover_source, flac: nil, duration: songDuration, waveform: [], seed: 0, abc: "", truncated: false)
        toggle(reference, title: project.songLabel)
    }
}
