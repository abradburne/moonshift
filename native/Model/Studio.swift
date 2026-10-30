import AppKit
import Observation

/// The app's state: the open cover, the library, running jobs, and the local engine.
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
    let updater: Updater

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
    /// A take's seed that the next takes of this cover reuse, instead of a new one each.
    var pinnedSeed: PinnedSeed?

    struct PinnedSeed: Equatable {
        var seed: Int
        var take: String
    }

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

    /// Covers waiting for a transcription before their take is queued. Covers of the same song share one.
    private var chains: [(job: String, cover: Project)] = []
    @ObservationIgnored private var saved = Project()
    @ObservationIgnored private var advancing: Set<String> = []
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<Bool, Never>?
    @ObservationIgnored private var estimating: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var settled: Set<String>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var folderAccess: URL?
    /// The tempo marked in each transcription's score, read once.
    @ObservationIgnored private var tempos: [String: Double?] = [:]
    #if SNAPSHOT
    @ObservationIgnored private var rehearsed = false
    #endif

    init() {
        Self.adoptEarlierSettings()
        presets = PresetStore()
        installer = Installer(root: service.root, scripts: service.code.appendingPathComponent("scripts"), helpers: service.isPackaged ? service.helpers : nil)
        updater = Updater(enabled: service.isPackaged)
        onlineLookup = UserDefaults.standard.bool(forKey: "CoverOnlineLookup")
        let fresh = newProject()
        saved = fresh
        project = fresh
        updater.start()
    }

    /// An update cannot replace the app while it is making a cover or installing models.
    var updateBlocker: String? {
        if runningJob != nil { return "Available once the cover being made is finished." }
        if installer.running { return "Available once setup has finished." }
        return nil
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
    var locked: Bool { submitting || importing || activeJob != nil || chains.contains { $0.cover.id == project.id } }
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
        !id.isEmpty && (jobs.contains { $0.active && $0.request.project.id == id } || chains.contains { $0.cover.id == id })
    }

    func takeCount(_ id: String) -> Int {
        jobs.reduce(0) { $0 + ($1.isGeneration && $1.request.project.id == id ? $1.tracks.count : 0) }
    }

    /// A finished transcription of this recording. Covers of the same song share it.
    func transcription(of source: String) -> Job? {
        jobs.first { $0.isTranscription && $0.status == "complete" && $0.request.source == source && !source.isEmpty }
    }

    /// The tempo heard in the original, once it has been transcribed.
    func originalTempo(of source: String) -> Double? {
        guard let job = transcription(of: source) else { return nil }
        if let known = tempos[job.id] { return known }
        let mark = job.result.abc?.firstMatch(of: #/(?m)^Q:\s*(?:\d+/\d+\s*=\s*)?(\d+)/#).flatMap { Double($0.1) }
        tempos[job.id] = mark
        return mark
    }

    /// How long the most recent finished take took to make, start to end.
    var lastTakeSeconds: Double? {
        jobs.lazy.filter { $0.isGeneration && $0.status == "complete" }
            .compactMap { job in job.started.flatMap { start in job.finished.map { $0.timeIntervalSince(start) } } }
            .first { $0 > 0 }
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
        // Coming from setup, the onboarding screen stays up while the library opens.
        if phase != .needsSetup { phase = .starting }
        #if SNAPSHOT
        // Screenshots can be taken before macOS has been asked to let this build into the folder.
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
            health = try await service.start()
        } catch {
            phase = .offline(error.localizedDescription)
            return
        }
        service.onChange = { [weak self] in Task { await self?.refresh() } }
        phase = .ready
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

    /// Setup finished: open the library if this was the first install, and see what is now available.
    func installFinished() async {
        if isReady {
            await refreshHealth()
            await refreshEstimate()
        } else {
            await start()
        }
    }

    /// The models and covers live in the project folder. macOS may ask the user
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
        if isReady { await save() }
        await service.stop()
        folderAccess?.stopAccessingSecurityScopedResource()
    }

    // MARK: Staying in sync

    /// The library tells the app when covers and jobs change; this only keeps what is
    /// installed and how much memory is free up to date.
    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: NSApp.isActive ? .seconds(5) : .seconds(15))
            if Task.isCancelled { return }
            await refreshHealth()
            // Free memory moves with whatever else is open.
            if step == .create, NSApp.isActive { await refreshEstimate() }
        }
    }

    func refresh() async {
        guard isReady, let state = service.state() else { return }
        apply(state)
    }

    func refreshHealth() async {
        guard isReady else { return }
        let value = await service.health()
        if value != health { health = value }
    }

    private func apply(_ state: LibraryState) {
        let covers = state.projects.filter { $0.app_mode == "covers" }
        if covers != projects { projects = covers }
        // An agent may have edited the open cover. Its changes are taken, and any unsaved
        // edits made here at the same time are kept on top of them and saved.
        if saving == nil, let stored = covers.first(where: { $0.id == project.id && !$0.id.isEmpty }),
           stored.updated_at > saved.updated_at, stored.content != project.content {
            let merged = isDirty ? Project.merge(local: project, base: saved, stored: stored) : stored
            saved = stored
            project = merged
        }
        guard state.jobs != jobs else { return }
        jobs = state.jobs

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
        guard let value = try? service.estimate(asked), project.content == asked.content else { return }
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
                let stored = try self.service.save(sent)
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
        pinnedSeed = nil
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
            let stored = try service.save(renamed)
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
            try service.deleteProject(target.id)
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
        // A new seed for each take, unless one is pinned: identical settings and seed repeat the same performance.
        project.seed = pinnedSeed?.seed ?? Int.random(in: 1..<2_000_000_000)
        guard await save() else { return }
        let snapshot = project
        let transcription = transcription(of: snapshot.cover_source)
        if transcription != nil || snapshot.hasEditedScore {
            // A pinned seed repeats a take, so its words stay exactly as they were.
            await generate(snapshot, from: transcription, labelling: pinnedSeed == nil)
        } else if let job = await submit(JobRequest(kind: "transcribe", project: snapshot, source: snapshot.cover_source)) {
            // An agent or another cover of this song may already be listening to it: this waits for that.
            chains.append((job.id, snapshot))
        }
    }

    /// Transcribes the recording without rendering, so its score can be read and edited first.
    func listen() async {
        guard isReady, !locked, project.hasSong, transcription(of: project.cover_source) == nil else { return }
        submitting = true
        defer { submitting = false }
        guard await save() else { return }
        await submit(JobRequest(kind: "transcribe", project: project, source: project.cover_source))
    }

    /// The score a take would be rendered from: an edited one, or what was heard in the recording.
    var score: String {
        if project.hasEditedScore { return project.abc }
        let heard = transcription(of: project.cover_source)?.result
        return (project.keepsHarmony ? heard?.full_abc : heard?.abc) ?? ""
    }

    /// How the lyrics sit on the score a take would use, at the cover's tempo.
    var lyricFit: LyricFit? { LyricFit(lyrics: project.lyrics, score: score, tempo: project.tempo) }

    /// Labels the lyrics with the score's sections now, rather than when the next take starts.
    func labelSections() {
        guard !locked, let labelled = LyricFit.labelled(project.lyrics, score: score) else { return }
        project.lyrics = labelled
    }

    /// Typing in the score makes it this cover's own; clearing it, or typing it back, returns to the original.
    func editScore(_ text: String) {
        let heard = transcription(of: project.cover_source)?.result
        let original = (project.keepsHarmony ? heard?.full_abc : heard?.abc) ?? ""
        let edited = !text.trimmed.isEmpty && text != original
        project.abc = edited ? text : ""
        project.score_edited = edited
    }

    private func advanceChains() {
        for (id, snapshot) in chains {
            guard let job = jobs.first(where: { $0.id == id }) else { chains.removeAll { $0.job == id }; continue }
            guard !job.active else { continue }
            if job.status == "complete" {
                // The cover stays locked until its music job is queued.
                guard advancing.insert(snapshot.id).inserted else { continue }
                Task {
                    await generate(snapshot, from: job)
                    chains.removeAll { $0.job == id && $0.cover.id == snapshot.id }
                    advancing.remove(snapshot.id)
                }
            } else {
                chains.removeAll { $0.job == id }
            }
        }
    }

    /// Queues the music job with the score heard in the reference song.
    private func generate(_ snapshot: Project, from transcription: Job?, resuming: Job? = nil, labelling: Bool = true) async {
        var cover = snapshot
        // A score edited by hand or by an agent is rendered as written.
        if !cover.hasEditedScore {
            guard let transcription, let score = cover.keepsHarmony ? transcription.result.full_abc : transcription.result.abc, !score.isEmpty else {
                notice = Notice(title: "No melody was found", message: "Moonshift could not hear a usable melody in this recording. Try a clearer recording of the song.")
                return
            }
            cover.abc = score
            cover.cover_job = transcription.id
        } else if cover.cover_job.isEmpty {
            cover.cover_job = transcription?.id ?? "edited"
        }
        // Unlabelled lyrics take the score's sections, which helps the singer keep its place.
        if resuming == nil, labelling, let labelled = LyricFit.labelled(cover.lyrics, score: cover.abc) { cover.lyrics = labelled }
        if cover.id == project.id {
            // The saved cover records which score and words it was made from.
            project.abc = cover.abc
            project.lyrics = cover.lyrics
            project.cover_job = cover.cover_job
            guard await save() else { return }
        }
        await submit(JobRequest(kind: "generate", project: cover, resumeFrom: resuming?.id ?? ""))
    }

    @discardableResult private func submit(_ request: JobRequest) async -> Job? {
        do {
            let job = try service.createJob(request)
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
            _ = try service.createJob(JobRequest(kind: "generate", project: cover, resumeFrom: job.id))
            await refresh()
        } catch {
            report(error, title: "Rendering could not resume")
        }
    }

    func cancel(_ job: Job) async {
        chains.removeAll { $0.job == job.id }
        do {
            try service.cancelJob(job.id)
            await refresh()
        } catch {
            report(error, title: "This job could not be cancelled")
        }
    }

    func delete(_ job: Job) async {
        if job.tracks.contains(where: { $0.audio == player.source }) { player.stop() }
        do {
            try service.deleteJob(job.id)
            await refresh()
        } catch {
            report(error, title: "This take could not be deleted")
        }
    }

    /// Brings back everything a take's performance came from, and pins its seed,
    /// so the next take repeats it: at another length, the same song grows or stops sooner.
    func reuseSeed(of track: AudioTrack, in job: Job) {
        let source = job.request.project
        project.lyrics = source.lyrics; project.style = source.style; project.voice = source.voice
        project.vocal_prompt = source.vocal_prompt; project.cover_preset = source.cover_preset; project.language = source.language
        project.cot = source.cot; project.tempo = source.tempo; project.cfg_scale = source.cfg_scale
        project.temperature = source.temperature; project.engine = source.engine; project.ode_steps = source.ode_steps
        editScore(source.abc)
        let made = job.created.map { " · " + $0.friendly } ?? ""
        pinnedSeed = PinnedSeed(seed: track.seed, take: "\(job.request.project.cover_preset.isEmpty ? track.name : job.request.project.cover_preset)\(made)")
        step = .create
    }

    /// Brings a take's style and singer back into the editor.
    func reuseSettings(of job: Job) {
        let source = job.request.project
        project.style = source.style; project.voice = source.voice; project.vocal_prompt = source.vocal_prompt
        project.cover_preset = source.cover_preset; project.cot = source.cot; project.language = source.language; project.tempo = source.tempo
        project.cfg_scale = source.cfg_scale
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
