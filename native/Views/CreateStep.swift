import SwiftUI

/// Step three: make the cover, watch it happen, and keep the takes.
struct CreateStep: View {
    @Bindable var studio: Studio
    @State private var installing = false

    /// What still stands between this cover and a take, most important first.
    private var blocker: String? {
        let project = studio.project
        if !project.hasSong { return "Add a song in the first step" }
        if !project.hasWords { return "Add the lyrics in the first step" }
        if !project.hasStyle { return "Describe the style in the second step" }
        if let estimate = studio.estimate, !estimate.allowed, studio.modelsReady { return estimate.reason }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeading(title: "Create the cover")
            summary
            ScoreSection(studio: studio)
            if studio.isReady, studio.health != nil, !studio.modelsReady { missingModels }
            if let job = studio.activeJob {
                JobProgressCard(studio: studio, job: job)
            } else if studio.locked {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Getting ready…") }.frame(maxWidth: .infinity, alignment: .leading).card()
            } else if let job = studio.setback {
                SetbackCard(studio: studio, job: job)
            }
            takes
        }
        .sheet(isPresented: $installing) { SetupSheet(studio: studio, quality: studio.project.quality) }
    }

    // MARK: Summary and options

    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Cover name", text: $studio.project.title).font(.title2.weight(.semibold)).textFieldStyle(.plain)
            HStack(spacing: 14) {
                facet(symbol: "moon.fill", tint: Theme.cool, label: "Song", value: studio.project.songLabel.isEmpty ? "None yet" : studio.project.songLabel)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                facet(symbol: "moon.fill", tint: Theme.accent, label: studio.project.keepsHarmony ? "Melody and harmony" : "Melody",
                      value: studio.project.cover_preset.isEmpty ? "Custom style" : studio.project.cover_preset)
            }
            Divider().opacity(0.6)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Length").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Length", selection: $studio.project.max_tokens) {
                            ForEach(CoverLength.allCases) { Text($0.name).tag($0.rawValue) }
                            // A cover saved with another budget keeps it.
                            if CoverLength(rawValue: studio.project.max_tokens) == nil { Text("Custom").tag(studio.project.max_tokens) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Text(lengthNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Tempo").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $studio.project.tempo, in: 0.7...1.3, step: 0.05).frame(width: 220).accessibilityLabel("Tempo")
                            Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
                            if studio.project.tempo != 1 { Button("Reset") { studio.project.tempo = 1 }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent) }
                        }
                        Text(tempoNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Quality").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Quality", selection: Binding(get: { studio.project.quality }, set: { studio.project.engine = $0.rawValue })) {
                            ForEach(Quality.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Text(studio.project.quality.detail + memoryNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 14) {
                // While this cover is being made, its own job is what holds the memory.
                if let blocker, !studio.locked { Callout(text: blocker) }
                Spacer(minLength: 0)
                Button { Task { await studio.createCover() } } label: {
                    Label(studio.takes.isEmpty ? "Create Cover" : "Create Another Take", systemImage: "sparkles")
                }
                .buttonStyle(.primaryLarge)
                .disabled(!studio.canCreate)
            }
        }
        .card(padding: 22)
        .disabled(studio.locked)
    }

    private func facet(symbol: String, tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 30, height: 30).background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tempo heard in the original, once it has been transcribed.
    private var originalBPM: Double? {
        guard let score = studio.transcription(of: studio.project.cover_source)?.result.abc,
              let mark = score.firstMatch(of: #/(?m)^Q:\s*(?:\d+/\d+\s*=\s*)?(\d+)/#) else { return nil }
        return Double(mark.1)
    }

    private var tempoNote: String {
        guard let bpm = originalBPM else { return studio.project.tempoLabel }
        let new = Int((bpm * studio.project.tempo).rounded())
        return studio.project.tempo == 1 ? "Original tempo · \(Int(bpm)) BPM" : "\(studio.project.tempoLabel) · \(Int(bpm)) → \(new) BPM"
    }

    private var lengthNote: String {
        let limit = "Stops by " + clockText(Double(studio.project.max_tokens) / 25) + "; a shorter song ends sooner."
        // A slower cover of the same song runs longer.
        let duration = studio.songDuration / studio.project.tempo
        guard duration > 0, let fit = CoverLength.fitting(duration) else { return limit }
        let song = studio.project.tempo == 1 ? "Your song is \(clockText(duration))." : "At this tempo your song runs about \(clockText(duration))."
        return fit.seconds > Double(studio.project.max_tokens) / 25 ? "\(song) \(fit.name) has room for all of it." : "\(song) \(limit)"
    }

    private var memoryNote: String {
        guard studio.modelsReady, let estimate = studio.estimate else { return "" }
        return String(format: " · needs about %.0f GB of memory", estimate.peak_high_gib.rounded(.up))
    }

    private var missingModels: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill").font(.title).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(studio.health?.transcriptionReady == true ? "\(studio.project.quality.name) quality needs its model" : "The local models are not installed yet").fontWeight(.medium)
                Text("They are downloaded once and run entirely on your Mac.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install…") { installing = true }.buttonStyle(.primary)
        }
        .card(padding: 16)
    }

    // MARK: Takes

    @ViewBuilder private var takes: some View {
        if !studio.takes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Takes")
                ForEach(studio.takes) { job in
                    ForEach(job.tracks) { track in TakeCard(studio: studio, job: job, track: track) }
                }
            }
        }
        if let transcription = studio.transcription(of: studio.project.cover_source), let preview = transcription.tracks.first {
            MelodyPreview(studio: studio, job: transcription, track: preview)
        }
    }
}

// MARK: Progress

/// The three movements of making a cover, and where this one is.
private struct JobProgressCard: View {
    var studio: Studio
    var job: Job

    private var phases: [(id: String, title: String)] { [("listen", "Listen"), ("compose", "Compose"), ("render", "Render")] }
    /// Index of the phase in progress. Saving audio belongs to rendering.
    private var current: Int {
        if job.isTranscription { return 0 }
        return job.phase == "render" || job.phase == "finish" ? 2 : 1
    }
    private var waiting: Bool { job.status == "queued" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    PhasePill(title: phase.title, state: waiting ? .pending : index < current ? .done : index == current ? .active : .pending)
                    if index < phases.count - 1 { Rectangle().fill(Theme.stroke).frame(height: 1).frame(maxWidth: 28) }
                }
                Spacer()
                if let started = job.started { ElapsedText(since: started).font(.callout).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(headline).font(.headline)
                if let progress = job.progress, !waiting {
                    ProgressView(value: min(1, max(0, progress))).tint(Theme.accent)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }
                HStack {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { Task { await studio.cancel(job) } }.buttonStyle(.quiet).controlSize(.small)
                }
            }
        }
        .card(padding: 20)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
    }

    private var headline: String {
        if waiting { return job.stage == "Queued" ? "Waiting for its turn" : job.stage }
        return job.stage.isEmpty ? "Working" : job.stage
    }

    private var detail: String {
        switch current {
        case 0: "Finding the melody and chords in your song. This happens once per recording."
        case 1: job.tokens > 0 ? "About \(clockText(Double(job.tokens) / 25)) of music written so far." : "Writing a new arrangement around the melody."
        default: "Turning the arrangement into sound. This is the longest part."
        }
    }
}

private struct PhasePill: View {
    enum State { case pending, active, done }
    var title: String
    var state: State

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .done: Image(systemName: "checkmark").font(.caption2.weight(.bold))
            case .active: Circle().fill(Theme.accent).frame(width: 7, height: 7)
            case .pending: Circle().strokeBorder(.tertiary).frame(width: 7, height: 7)
            }
            Text(title).font(.callout.weight(state == .active ? .semibold : .regular))
        }
        .foregroundStyle(state == .pending ? AnyShapeStyle(.tertiary) : state == .active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(state == .active ? Theme.accent.opacity(0.13) : Theme.surface, in: Capsule())
    }
}

/// The last attempt stopped before finishing. Says why, and what can be done.
private struct SetbackCard: View {
    var studio: Studio
    var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Callout(text: job.status == "cancelled" ? "The last attempt was cancelled." : job.error.isEmpty ? "The last attempt did not finish." : job.error)
            if job.resumable {
                HStack {
                    Text("The song it wrote was saved, so only the audio needs rendering.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Resume Rendering") {
                        Button("Resume") { Task { await studio.resume(job, inSections: false) } }
                        Button("Resume in Sections (steadier on long songs)") { Task { await studio.resume(job, inSections: true) } }
                    }
                    .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }
}

// MARK: Takes

private struct TakeCard: View {
    var studio: Studio
    var job: Job
    var track: AudioTrack
    @State private var confirmingDelete = false

    private var isCurrent: Bool { studio.player.source == track.audio }
    private var snapshot: Project { job.request.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button { studio.toggle(track, title: snapshot.title) } label: {
                    Image(systemName: isCurrent && studio.player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.onAccent)
                        .frame(width: 44, height: 44).background(Theme.accent.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCurrent && studio.player.playing ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(snapshot.cover_preset.isEmpty ? "Custom style" : snapshot.cover_preset).font(.headline).lineLimit(1)
                        if studio.unheard.contains(track.id) {
                            Text("New").font(.caption2.weight(.bold)).foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent, in: Capsule())
                        }
                    }
                    Text(facts).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Export WAV…", systemImage: "square.and.arrow.up") { studio.export(track, of: job, lossless: false) }
                    if track.flac != nil { Button("Export FLAC…", systemImage: "square.and.arrow.up") { studio.export(track, of: job, lossless: true) } }
                    Button("Show in Finder", systemImage: "folder") { studio.reveal(track) }
                    Divider()
                    Button("Use This Style Again", systemImage: "arrow.uturn.backward") { studio.reuseSettings(of: job) }.disabled(studio.locked)
                    Divider()
                    Button("Delete Take…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Export, reuse or delete this take")
            }
            WaveformView(samples: track.waveform, progress: isCurrent && studio.player.duration > 0 ? studio.player.position / studio.player.duration : nil,
                         onSeek: isCurrent ? { studio.player.seek($0 * studio.player.duration) } : nil)
                .frame(height: 44)
            if track.truncated {
                Callout(text: "This take reached its length limit. Choose a longer length to hear the whole song.", symbol: "scissors")
            }
        }
        .card(padding: 16)
        .confirmationDialog("Delete this take?", isPresented: $confirmingDelete) {
            Button("Delete Take", role: .destructive) { Task { await studio.delete(job) } }
        } message: {
            Text("Its audio will be removed. This cannot be undone.")
        }
    }

    private var facts: String {
        var parts = [clockText(track.duration), snapshot.quality.bits, snapshot.keepsHarmony ? "Melody and harmony" : "Melody"]
        if snapshot.tempo != 1 { parts.append(snapshot.tempoLabel) }
        if let voice = Voice.named(snapshot.voice) { parts.append(voice.name) }
        if let created = job.created { parts.append(created.friendly) }
        return parts.joined(separator: " · ")
    }
}

/// A plain rendering of the melody Moonshift heard, for checking the transcription.
private struct MelodyPreview: View {
    var studio: Studio
    var job: Job
    var track: AudioTrack

    var body: some View {
        let playing = studio.player.source == track.audio && studio.player.playing
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { studio.toggle(track, title: "Melody heard in the original") } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 30, height: 30).background(Theme.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Pause" : "Play the melody")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Melody heard in the original").fontWeight(.medium)
                    Text("A simple note preview. If it sounds wrong, try a cleaner recording.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(job.result.warnings ?? [], id: \.self) { Callout(text: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

/// The ABC score the cover is rendered from: tucked away, but there to read and change.
private struct ScoreSection: View {
    @Bindable var studio: Studio
    @AppStorage("ScoreExpanded") private var expanded = false

    private var listening: Bool { studio.activeJob?.isTranscription == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Score").font(.headline)
                    if studio.project.hasEditedScore {
                        Text("Edited").font(.caption2.weight(.bold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent, in: Capsule())
                    }
                    Spacer()
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide the score" : "Show the score")

            if expanded {
                if studio.score.isEmpty {
                    HStack(spacing: 12) {
                        Text(studio.project.hasSong ? "The score is written when Moonshift listens to the song. That happens with your first take, or now."
                             : "Add a song first. Its score is written when Moonshift listens to it.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if listening { ProgressView().controlSize(.small) }
                        Button("Listen Now") { Task { await studio.listen() } }
                            .buttonStyle(.quiet)
                            .disabled(!studio.project.hasSong || studio.locked || studio.health?.transcriptionReady != true)
                    }
                } else {
                    LyricsEditor(text: Binding(get: { studio.score }, set: { studio.editScore($0) }), score: true)
                        .frame(height: 260)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .disabled(studio.locked)
                    HStack(spacing: 12) {
                        Text("ABC notation. Change notes, the chords in quotes, or the Q: tempo. Takes follow what is written here.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if studio.project.hasEditedScore {
                            Button("Use Original Score") { studio.editScore("") }.buttonStyle(.quiet).disabled(studio.locked)
                        }
                    }
                }
            }
        }
        .card(padding: 16)
    }

    private var summary: String {
        if studio.score.isEmpty { return listening ? "Listening…" : "Not written yet" }
        return studio.project.keepsHarmony ? "Melody and chords" : "Melody"
    }
}
