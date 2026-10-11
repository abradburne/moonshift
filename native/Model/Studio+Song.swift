import AppKit
import UniformTypeIdentifiers

/// The reference song: importing it, naming it, finding its words, and exporting takes.
extension Studio {
    static let audioExtensions = ["wav", "flac", "mp3", "aiff", "aif", "m4a"]
    static let audioTypes = audioExtensions.compactMap { UTType(filenameExtension: $0) }

    // MARK: Recording

    func chooseSong() {
        guard isReady, !locked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        panel.message = "Choose the song to cover"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importSong(url) }
    }

    func importSong(_ url: URL) async {
        guard isReady, !locked else { return }
        guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else {
            notice = Notice(title: "That file is not a supported recording", message: "Choose WAV, FLAC, MP3, AIFF or M4A audio.")
            return
        }
        importing = true
        defer { importing = false }
        let target = project.id
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 512 * 1024 * 1024 else { throw ServiceError(message: "Choose a recording up to 512 MB.") }
            let source = try await service.upload(url)
            guard project.id == target else { return }
            if player.source == project.cover_source { player.stop() }
            project.cover_source = source
            project.cover_name = url.deletingPathExtension().lastPathComponent
            // A different recording needs its own score and its own name; typed lyrics stay.
            project.abc = ""; project.cover_job = ""
            project.song_title = ""; project.song_artist = ""
            step = .song
            await save()
            await loadSongDetails()
        } catch {
            report(error, title: "This song could not be imported")
        }
    }

    func resetLookup() {
        lookupToken = UUID()
        lookupBusy = false
        candidates = []
        reviewing = nil
        lookupMessage = ""
        songDuration = 0
    }

    /// Reads the recording's length and, for a new song, its title from tags or the filename.
    func loadSongDetails() async {
        guard isReady, project.hasSong else { return }
        let source = project.cover_source
        struct Query: Encodable { var source: String; var name: String }
        do {
            let details: SongDetails = try await service.post("cover/metadata", Query(source: source, name: project.cover_name))
            guard project.cover_source == source else { return }
            songDuration = details.duration ?? 0
            // Never replace what the user typed while this was loading.
            let unnamed = project.song_title.isEmpty
            if unnamed { project.song_title = details.title }
            if project.song_artist.isEmpty { project.song_artist = details.artist }
            if project.title == Project.untitled, !details.title.isEmpty { project.title = String(details.title.prefix(160)) }
            if unnamed, onlineLookup, !project.hasWords { await identifyAndSearch() }
        } catch {
            guard project.cover_source == source else { return }
            lookupMessage = error.localizedDescription
        }
    }

    // MARK: Optional online lookup

    /// Sends an audio fingerprint to Shazam, then looks for lyrics by name.
    func identifyAndSearch() async {
        guard onlineLookup, !lookupBusy, project.hasSong else { return }
        lookupBusy = true
        let token = lookupToken, source = project.cover_source
        let typed = (project.song_title, project.song_artist)
        struct Query: Encodable { var source: String }
        do {
            let match: SongDetails = try await service.post("cover/identify", Query(source: source), timeout: 65)
            guard lookupToken == token, project.cover_source == source else { return }
            if !match.title.isEmpty, (project.song_title, project.song_artist) == typed {
                project.song_title = match.title
                project.song_artist = match.artist
            }
            lookupMessage = match.note ?? ""
        } catch {
            if lookupToken == token { lookupMessage = error.localizedDescription }
        }
        guard lookupToken == token else { return }
        lookupBusy = false
        await searchLyrics()
    }

    /// Sends the title and artist to LRCLIB.
    func searchLyrics() async {
        guard onlineLookup, !lookupBusy, !project.song_title.trimmed.isEmpty else { return }
        lookupBusy = true
        candidates = []
        let token = lookupToken
        struct Query: Encodable { var title: String; var artist: String; var duration: Double }
        struct Results: Decodable { var candidates: [LyricCandidate] }
        do {
            let query = Query(title: project.song_title, artist: project.song_artist, duration: songDuration)
            let results: Results = try await service.post("cover/lyrics/search", query)
            guard lookupToken == token else { return }
            candidates = results.candidates
            lookupMessage = candidates.isEmpty ? "No lyrics found for that title. Paste the words, or import a lyric file." : ""
        } catch {
            if lookupToken == token { lookupMessage = error.localizedDescription }
        }
        if lookupToken == token { lookupBusy = false }
    }

    func useLyrics(_ candidate: LyricCandidate) {
        project.lyrics = candidate.lyrics
        project.lyrics_source = candidate.source
        project.song_title = candidate.title
        project.song_artist = candidate.artist
        reviewing = nil
        candidates = []
        lookupMessage = ""
    }

    // MARK: Lyric files

    func importLyrics() {
        guard isReady, !locked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["txt", "srt", "lrc", "vtt"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a lyric or subtitle file. Timings are removed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = project.id, before = project.lyrics
        Task {
            struct Input: Encodable {
                var text: String
                var fileExtension: String
                enum CodingKeys: String, CodingKey { case text; case fileExtension = "extension" }
            }
            struct Parsed: Decodable { var lyrics: String }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_000_000 else { throw ServiceError(message: "Choose a lyric file up to 1 MB.") }
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                let parsed: Parsed = try await service.post("cover/lyrics/import", Input(text: text, fileExtension: "." + url.pathExtension.lowercased()))
                // Keep anything typed while the file was being read.
                guard project.id == target, project.lyrics == before else { return }
                project.lyrics = parsed.lyrics
                project.lyrics_source = url.lastPathComponent
            } catch {
                report(error, title: "These lyrics could not be imported")
            }
        }
    }

    // MARK: Takes on disk

    func export(_ track: AudioTrack, of job: Job, lossless: Bool) {
        let relative = lossless ? track.flac ?? track.audio : track.audio
        let source = service.file(relative)
        let panel = NSSavePanel()
        let name = job.request.project.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(name).\(source.pathExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: source.pathExtension) ?? .audio]
        panel.directoryURL = (UserDefaults.standard.url(forKey: "ExportFolder")) ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        UserDefaults.standard.set(target.deletingLastPathComponent(), forKey: "ExportFolder")
        do {
            // The save panel has already confirmed replacing an existing file.
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            report(error, title: "This take could not be exported")
        }
    }

    func reveal(_ track: AudioTrack) {
        NSWorkspace.shared.activateFileViewerSelecting([service.file(track.audio)])
    }
}
