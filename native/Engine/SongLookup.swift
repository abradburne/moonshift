import AVFoundation
import Foundation

/// Naming a recording and finding its words: local tags first, then, only when
/// the user has turned it on, LRCLIB for lyrics and Shazam for identification.
enum SongLookup {
    static let audioExtensions = ["wav", "flac", "mp3", "aiff", "aif", "m4a"]
    static let longest = 900.0

    // MARK: Local details

    /// The recording's length, and its title and artist from tags or, failing that, the filename.
    static func details(of file: URL, name: String) async throws -> SongDetails {
        let unreadable = ServiceError("This audio could not be read. Choose a playable recording up to 15 minutes long.")
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0, duration <= longest else {
            throw unreadable
        }
        var tags: [String: String] = [:]
        for item in (try? await asset.load(.metadata)) ?? [] {
            guard let key = tagName(item), tags[key] == nil,
                  let value = try? await item.load(.stringValue)?.trimmed, !value.isEmpty else { continue }
            tags[key] = value
        }
        return details(duration: duration, tags: tags, name: name)
    }

    /// Title or artist, whichever tag format the file uses.
    private static func tagName(_ item: AVMetadataItem) -> String? {
        if item.commonKey == .commonKeyTitle { return "title" }
        if item.commonKey == .commonKeyArtist { return "artist" }
        // Vorbis comments in FLAC, and RIFF INFO chunks, have no common key.
        let key = (item.key as? String)?.lowercased() ?? ""
        if ["title", "inam"].contains(key) { return "title" }
        if ["artist", "iart"].contains(key) { return "artist" }
        return nil
    }

    static func details(duration: Double, tags: [String: String], name: String) -> SongDetails {
        var title = tags["title"] ?? ""
        var artist = tags["artist"] ?? ""
        let tagged = !title.isEmpty
        if title.isEmpty {
            let file = URL(fileURLWithPath: name)
            var filename = audioExtensions.contains(file.pathExtension.lowercased()) ? file.deletingPathExtension().lastPathComponent : name
            filename = filename.replacingPattern(#"^\d+[. _-]+"#, with: "")
            if let separator = filename.range(of: " - ") {
                if artist.isEmpty { artist = String(filename[..<separator.lowerBound]) }
                title = String(filename[separator.upperBound...])
            } else {
                title = filename
            }
        }
        return SongDetails(title: String(title.prefix(300)), artist: String(artist.prefix(300)), duration: duration,
                           method: tagged ? "tags" : "filename")
    }

    // MARK: LRCLIB

    struct Record: Decodable {
        var id: Int
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    static func searchLyrics(title: String, artist: String, duration: Double) async throws -> [LyricCandidate] {
        guard !title.trimmed.isEmpty else { throw ServiceError("Enter a song title to look for lyrics.") }
        var address = URLComponents(string: "https://lrclib.net/api/search")!
        address.queryItems = [URLQueryItem(name: "track_name", value: title.trimmed)]
        if !artist.trimmed.isEmpty { address.queryItems?.append(URLQueryItem(name: "artist_name", value: artist.trimmed)) }
        var request = URLRequest(url: address.url!, timeoutInterval: 15)
        request.setValue("Moonshift/1.3 (personal local music app)", forHTTPHeaderField: "User-Agent")
        let unavailable = ServiceError("The lyric service is unavailable. Try later, import a lyric file, or paste the words.")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { throw unavailable }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw unavailable }
        guard let records = try? JSONDecoder().decode([Record].self, from: data) else {
            throw ServiceError("The lyric service returned an unexpected response. Import or paste lyrics instead.")
        }
        return candidates(records, title: title, artist: artist, duration: duration)
    }

    /// Exact title first, then the same artist, then the closest length; at most six with words.
    static func candidates(_ records: [Record], title: String, artist: String, duration: Double) -> [LyricCandidate] {
        func rank(_ record: Record) -> (Int, Int, Double) {
            let exact = normalized(record.trackName ?? "") == normalized(title)
            let sameArtist = !artist.isEmpty && normalized(record.artistName ?? "") == normalized(artist)
            let difference = duration > 0 ? abs((record.duration ?? 0) - duration) : 0
            return (exact ? 0 : 1, sameArtist ? 0 : 1, difference)
        }
        let ordered = records.enumerated().sorted { a, b in
            let (x, y) = (rank(a.element), rank(b.element))
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        var found: [LyricCandidate] = []
        for record in ordered where record.instrumental != true {
            let plain = record.plainLyrics ?? ""
            let text = plain.isEmpty ? record.syncedLyrics ?? "" : plain
            guard !text.isEmpty, let lyrics = try? LyricFile.parse(text, extension: plain.isEmpty ? "lrc" : "txt") else { continue }
            found.append(LyricCandidate(id: record.id, title: record.trackName ?? "", artist: record.artistName ?? "",
                                        album: record.albumName ?? "", duration: record.duration ?? 0, lyrics: lyrics,
                                        source: "https://lrclib.net/api/get/\(record.id)"))
            if found.count == 6 { break }
        }
        return found
    }

    /// Case, accents of width, and punctuation do not distinguish two titles.
    static func normalized(_ value: String) -> String {
        let folded = value.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }.map(Character.init))
    }

    // MARK: Shazam

    /// Decodes a short excerpt locally and asks the optional helper to name it.
    static func identify(_ file: URL, paths: Paths) async throws -> SongDetails {
        guard paths.lookupInstalled else {
            return SongDetails(title: "", artist: "", note: "Audio identification is not installed yet. You can search by song name or install lookup in Settings.")
        }
        let unavailable = ServiceError("Song identification is unavailable. Enter the song name and search, or import lyrics.")
        guard let ffmpeg = paths.ffmpeg else { throw unavailable }
        let folder = paths.temporary.appendingPathComponent("identify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let excerpt = folder.appendingPathComponent("excerpt.wav")
        let decoded = try await run(ffmpeg, ["-v", "error", "-nostdin", "-i", file.path, "-t", "24", "-ac", "1", "-ar", "16000", excerpt.path],
                                    paths: paths, timeout: 20)
        guard decoded.status == 0 else { throw unavailable }
        let named = try await run(paths.lookupPython, ["-m", "studio.recognize", excerpt.path], paths: paths, timeout: 35)
        guard named.status == 0, let match = try? JSONDecoder().decode(SongDetails.self, from: named.output) else {
            return SongDetails(title: "", artist: "", note: "Online identification is unavailable. Check the song details and search for lyrics, or import a lyric file.")
        }
        return match
    }

    private static func run(_ executable: URL, _ arguments: [String], paths: Paths, timeout: TimeInterval) async throws -> (status: Int32, output: Data) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = paths.code
            process.environment = paths.environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, data))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }
}
