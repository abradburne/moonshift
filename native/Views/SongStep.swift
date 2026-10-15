import SwiftUI

/// Step one: the recording to cover, and its words.
struct SongStep: View {
    @Bindable var studio: Studio
    @State private var askingAboutLookup = false

    private var hint: String? {
        if !studio.project.hasSong { return "Add the song you want to cover" }
        if !studio.project.hasWords { return "Add the lyrics" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeading(title: "Start with a song")
            if studio.activeJob != nil { LockedBanner(studio: studio) }

            Group {
                if studio.importing {
                    HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Importing your song…") }
                        .frame(maxWidth: .infinity, minHeight: 96).card()
                } else if studio.project.hasSong {
                    songCard
                } else {
                    dropZone
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Lyrics") {
                        if studio.lookupBusy { ProgressView().controlSize(.small) }
                        Button("Find Online", systemImage: "magnifyingglass") { findOnline() }
                            .disabled(!studio.project.hasSong || studio.lookupBusy)
                            .help("Look for this song's lyrics on LRCLIB")
                        Button("Import File…", systemImage: "doc.text") { studio.chooseLyrics() }
                            .help("Use a TXT, SRT, LRC, WebVTT or TTML file, or drop one on the window")
                    }
                    if !studio.lookupMessage.isEmpty { Text(studio.lookupMessage).font(.callout).foregroundStyle(.secondary) }
                    if !studio.candidates.isEmpty { candidates }
                    LyricsEditor(text: $studio.project.lyrics) {
                        // Provenance follows the words: clearing them clears where they came from.
                        if !studio.project.hasWords { studio.project.lyrics_source = "" }
                    }
                        .frame(height: 320)
                        .overlay(alignment: .topLeading) {
                            if studio.project.lyrics.isEmpty {
                                Text("Paste the words here.\nLabel sections like [Verse] and [Chorus] to guide the arrangement.")
                                    .foregroundStyle(.tertiary).lineSpacing(4).padding(.horizontal, 19).padding(.vertical, 16).allowsHitTesting(false)
                            }
                        }
                        .card(padding: 0)
                    if let source = lyricsSource { Text(source).font(.caption).foregroundStyle(.tertiary) }
                }
            }
            .disabled(studio.locked)

            StepFooter(hint: hint) {
                Button("Continue") { studio.step = .style }
                    .buttonStyle(.primary)
                    .disabled(hint != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog("Look up songs online?", isPresented: $askingAboutLookup) {
            Button("Turn On Lookup") {
                studio.onlineLookup = true
                findOnline()
            }
        } message: {
            Text("To find lyrics, Moonshift sends the song's title and artist to LRCLIB. To name a recording it does not recognise, it sends a short audio fingerprint to Shazam. Your recordings and covers never leave your Mac. You can turn this off in Settings.")
        }
    }

    private var lyricsSource: String? {
        let source = studio.project.lyrics_source
        if source.isEmpty { return nil }
        return source.contains("lrclib.net") ? "Lyrics from LRCLIB" : "Lyrics from \(source)"
    }

    private func findOnline() {
        guard studio.onlineLookup else { askingAboutLookup = true; return }
        Task {
            if studio.project.song_title.trimmed.isEmpty { await studio.identifyAndSearch() } else { await studio.searchLyrics() }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.cool)
            Text("Drop a song here").font(.title3.weight(.semibold))
            Button("Choose File…") { studio.chooseSong() }.buttonStyle(.primary).disabled(!studio.isReady)
            Text("WAV, FLAC, MP3, AIFF or M4A, up to 15 minutes").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Theme.cool.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.cool.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
    }

    private var songCard: some View {
        let playing = studio.player.source == studio.project.cover_source && studio.player.playing
        return HStack(spacing: 16) {
            Button { studio.toggleReference() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17)).foregroundStyle(Theme.background)
                    .frame(width: 46, height: 46).background(Theme.cool.gradient, in: Circle())
            }
            .buttonStyle(.plain)
            .help(playing ? "Pause" : "Play the original")
            .accessibilityLabel(playing ? "Pause" : "Play the original")

            VStack(alignment: .leading, spacing: 3) {
                TextField("Song title", text: $studio.project.song_title).font(.title3.weight(.semibold)).textFieldStyle(.plain)
                TextField("Artist", text: $studio.project.song_artist).foregroundStyle(.secondary).textFieldStyle(.plain)
            }
            Spacer(minLength: 8)
            if studio.songDuration > 0 { Text(clockText(studio.songDuration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            Menu {
                Button("Replace Song…", systemImage: "arrow.triangle.2.circlepath") { studio.chooseSong() }
                if studio.onlineLookup {
                    Button("Identify with Shazam", systemImage: "waveform.badge.magnifyingglass") { Task { await studio.identifyAndSearch() } }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("More")
        }
        .card(padding: 16)
    }

    private var candidates: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(studio.candidates) { candidate in
                if candidate != studio.candidates.first { Divider().opacity(0.5) }
                Button { studio.reviewing = candidate } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).fontWeight(.medium)
                            Text([candidate.artist, candidate.album, clockText(candidate.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card(padding: 0)
    }
}

/// Shown while the open cover is being created.
struct LockedBanner: View {
    var studio: Studio

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("This cover is being created. Editing is paused until it finishes.")
            Spacer()
            if studio.step != .create { Button("Show Progress") { studio.step = .create }.buttonStyle(.quiet) }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A lyric version found online, shown in full before it replaces anything.
struct LyricReviewSheet: View {
    var studio: Studio
    var candidate: LyricCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title).font(.title2.weight(.semibold))
                Text([candidate.artist, candidate.album, clockText(candidate.duration)].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(candidate.lyrics).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(height: 360)
            .card(padding: 0)
            HStack {
                if let url = URL(string: candidate.source) { Link("Source: LRCLIB", destination: url).font(.caption) }
                Spacer()
                Button("Cancel") { studio.reviewing = nil }.keyboardShortcut(.cancelAction)
                Button(studio.project.hasWords ? "Replace Lyrics" : "Use These Lyrics") { studio.useLyrics(candidate) }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
