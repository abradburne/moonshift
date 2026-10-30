import AVFoundation
import Darwin
import Foundation

// MARK: Lyric files

await test("subtitle formats keep sung repetition") {
    let cases: [(String, String, String)] = [
        ("srt", "1\r\n00:00:01,000 --> 00:00:03,000\r\n<i>Come home</i>\r\n\r\n2\r\n00:00:04,000 --> 00:00:06,000\r\nCome home", "Come home\n\nCome home"),
        ("lrc", "[ar:Artist]\n[ti:Title]\n[offset:0]\n[00:01.20]Come <00:02.00>home\n[00:04.20][00:06.00]Come home\n[Chorus]\nStay", "Come home\nCome home\n[Chorus]\nStay"),
        ("vtt", "WEBVTT\n\nNOTE ignore this\nprivate cue note\n\nintro\n00:01.000 --> 00:03.000 align:start\n<v Singer>Come &amp; stay</v>\n\n00:04.000 --> 00:06.000\nCome &amp; stay", "Come & stay\n\nCome & stay"),
        ("ttml", #"<?xml version="1.0" encoding="UTF-8"?><tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word"><head><metadata><iTunesMetadata><translations><translation><text for="L1">Ignore me</text></translation></translations></iTunesMetadata></metadata></head><body><div itunes:song-part="Verse"><p begin="1.0" end="3.0"><span begin="1.0" end="1.5">Come</span> <span begin="1.5" end="2.0">ho</span><span begin="2.0" end="3.0">me</span><span ttm:role="x-bg"><span>stay</span></span></p><p>Rock &amp; roll<br/>Again</p></div><div itunes:song-part="PreChorus"><p>Come home</p></div><div><p>Come home</p></div></body></tt>"#,
         "[Verse]\nCome home (stay)\nRock & roll\nAgain\n\n[Pre-Chorus]\nCome home\n\nCome home"),
        ("txt", "\u{FEFF}[Verse]\n123\nCome home\n\n[Chorus]\nCome home", "[Verse]\n123\nCome home\n\n[Chorus]\nCome home"),
    ]
    for (kind, text, expected) in cases {
        let parsed = try LyricFile.parse(text, extension: kind)
        check(parsed == expected, "\(kind): \(parsed.debugDescription)")
    }
    check(try LyricFile.parse("Hi", extension: ".TXT") == "Hi")
    check(try LyricFile.parse("[la:en]\n[au:Writer]\n[id:abc]\n[#:note]\n[00:01.00]Words", extension: "lrc") == "Words")
    check(LyricFile.decode(Data("こんにちは".data(using: .shiftJIS)!)) == "こんにちは")
    check(LyricFile.decode(Data("Café".data(using: .windowsCP1252)!))?.hasPrefix("Caf") == true)
    check(LyricFile.decode(Data("Plain".utf8)) == "Plain")
}

await test("empty, oversized and unsafe lyric files are refused") {
    checkThrows { _ = try LyricFile.parse("1\n00:01:00,000 --> 00:01:01,000", extension: "srt") }
    checkThrows({ _ = try LyricFile.parse(String(repeating: "x", count: 18001), extension: "txt") }, containing: "18,000")
    checkThrows { _ = try LyricFile.parse(#"<!DOCTYPE tt [<!ENTITY a "aaaa">]><tt><body><p>&a;</p></body></tt>"#, extension: "ttml") }
    checkThrows({ _ = try LyricFile.parse("<tt><body><p>Unclosed</body></tt>", extension: "ttml") }, containing: "could not be read")
}

// MARK: Lyrics and score

let sectionedScore = """
X:1
M:4/4
L:1/8
Q:1/4=120
V: Vocal clef=treble name="Vocal Melody"
V: Ins clef=treble name="Ins Melody"
K:C
% intro
V: Vocal
Z2|
V: Ins
"C"C8|C8|
% verse
V: Vocal
"C"cccc cccc|cccc cccc|
V: Ins
Z2|
% chorus
V: Vocal
c4-c4|cccc cccc|[ce]ccc cccc|]
"""

await test("the score's sections count the notes its vocal line begins") {
    let sections = LyricFit.sections(of: sectionedScore)
    check(sections.map(\.name) == ["intro", "verse", "chorus"])
    // A tied note is one note; a chord is one note; the instrument's notes do not count.
    check(sections.map(\.notes) == [0, 16, 17], "\(sections.map(\.notes))")
    check(sections.map(\.start) == [0, 4, 8], "\(sections.map(\.start))")
    check(LyricFit.sections(of: sectionedScore, tempo: 0.5).last?.start == 16)
    check(LyricFit.sections(of: "X:1\nM:4/4\nK:C\ncdef|]").isEmpty)
}

await test("lyrics are labelled with the score's sections") {
    // The blank line inside the chorus is not a section break.
    let lyrics = "Walking down the road tonight\nLooking for a little light\n\nSing it loud and sing it clear\n\nEveryone is gathered here"
    let labelled = LyricFit.labelled(lyrics, score: sectionedScore)
    check(labelled == "[Verse]\nWalking down the road tonight\nLooking for a little light\n\n[Chorus]\nSing it loud and sing it clear\nEveryone is gathered here",
          labelled ?? "nil")
    check(LyricFit(lyrics: lyrics, score: sectionedScore)?.problems == [])
    // Lyrics with their own labels, or a score without sections, are left alone.
    check(LyricFit.labelled(labelled ?? "", score: sectionedScore) == nil)
    check(LyricFit.labelled(lyrics, score: "X:1\nK:C\ncdef|]") == nil)
    check(LyricFit.Section.titled("pre-chorus") == "Pre-Chorus")
}

await test("a section with more words than notes is pointed out") {
    let lyrics = "Walking down the road tonight\nLooking for a little light\n\n" + Array(repeating: "Sing it loud and sing it clear", count: 5).joined(separator: "\n")
    let fit = LyricFit(lyrics: lyrics, score: sectionedScore, tempo: 0.5)
    check(fit?.problems.contains(.crowded(section: 2)) == true, "\(fit?.problems ?? [])")
    check(fit?.messages.contains { $0.hasPrefix("Chorus at 0:16 has") && $0.hasSuffix("17 notes. Lines there may be rushed or skipped.") } == true,
          "\(fit?.messages ?? [])")
}

await test("syllables are counted in English and Japanese") {
    check(LyricFit.syllables("Close your eyes and count to three") == 7)
    check(LyricFit.syllables("My heart beats like a drum (all night)") == 6)
    check(LyricFit.syllables("こんにちは きょう") == 7)
}

// MARK: Song details

await test("titles come from tags, then from the filename") {
    let tagged = SongLookup.details(duration: 123.5, tags: ["title": "Tagged song", "artist": "Tagged artist"], name: "File title")
    check(tagged == SongDetails(title: "Tagged song", artist: "Tagged artist", duration: 123.5, method: "tags"))
    let named = SongLookup.details(duration: 120, tags: [:], name: "01 Artist - Song.mp3")
    check(named.title == "Song" && named.artist == "Artist" && named.method == "filename")
}

await test("a recording's length is read locally") {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("Moonshift Test - Tone.wav")
    try writeTone(wav, seconds: 1.5)
    let details = try await SongLookup.details(of: wav, name: wav.lastPathComponent)
    check(abs((details.duration ?? 0) - 1.5) < 0.01, "\(details)")
    check(details.title == "Tone" && details.artist == "Moonshift Test")
    let text = FileManager.default.temporaryDirectory.appendingPathComponent("notes.wav")
    try Data("not audio".utf8).write(to: text)
    do { _ = try await SongLookup.details(of: text, name: "notes.wav"); check(false, "read a text file") } catch { check(true) }
}

await test("LRCLIB results rank exact titles, the same artist and length") {
    let records = [
        SongLookup.Record(id: 1, trackName: "Home (Live)", artistName: "Singer", duration: 200, plainLyrics: "Live words"),
        SongLookup.Record(id: 2, trackName: "home", artistName: "Other", duration: 200, plainLyrics: "Other words"),
        SongLookup.Record(id: 3, trackName: "Home", artistName: "Singer", duration: 260, plainLyrics: "Far words"),
        SongLookup.Record(id: 4, trackName: "Home", artistName: "Singer", duration: 201, syncedLyrics: "[00:01.00]Close words"),
        SongLookup.Record(id: 5, trackName: "Home", artistName: "Singer", duration: 200, instrumental: true),
    ]
    let found = SongLookup.candidates(records, title: "Home", artist: "SINGER", duration: 200)
    check(found.map(\.id) == [4, 3, 2, 1], "\(found.map(\.id))")
    check(found.first?.lyrics == "Close words" && found.first?.source == "https://lrclib.net/api/get/4")
}

// MARK: Estimates

let memory = MemoryState(total_gib: 36, available_gib: 28, free_gib: 2, limit_gib: 21.6, reserve_gib: 6)

await test("estimates follow length, guidance and precision") {
    let estimator = Estimator(installed: { _ in true }, coversInstalled: { true })
    var project = Project()
    project.engine = "metal-q8"; project.max_tokens = 9000; project.cot = "full"
    let one = estimator.estimate(project, memory: memory)
    var eight = project; eight.takes = 8
    var guided = project; guided.cfg_scale = 1.2
    var small = project; small.engine = "metal-q4"
    check(one.duration_ceiling_seconds == 360 && one.allowed)
    check(estimator.estimate(eight, memory: memory).peak_high_gib == one.peak_high_gib)
    check(estimator.estimate(guided, memory: memory).cache_gib > one.cache_gib * 1.9)
    check(estimator.estimate(small, memory: memory).peak_high_gib < one.peak_high_gib)
    // A sketch holds a full first chunk of cache, as long a song would.
    var sketch = project; sketch.max_tokens = 1500
    var chunk = project; chunk.max_tokens = 5120
    check(estimator.estimate(sketch, memory: memory).cache_gib == estimator.estimate(chunk, memory: memory).cache_gib)
    var tight = memory; tight.limit_gib = 8
    let constrained = estimator.estimate(project, memory: tight)
    check(!constrained.allowed && constrained.reason.contains("memory limit"))
    var automatic = project; automatic.engine = "auto"
    var less = memory; less.available_gib = 16
    let chosen = estimator.estimate(automatic, memory: less)
    check(chosen.allowed && chosen.engine == "metal-q4" && chosen.selection_note?.contains("Automatic chose 4-bit") == true)
}

await test("low memory and missing models are refused") {
    var project = Project(); project.engine = "metal-q4"; project.max_tokens = 1500
    var low = memory; low.available_gib = 7
    let refused = Estimator(installed: { _ in true }, coversInstalled: { true }).estimate(project, memory: low)
    check(!refused.allowed && refused.reason.contains("available memory"))
    let missing = Estimator(installed: { _ in false }, coversInstalled: { false })
    project.engine = "metal-q8"
    check(missing.estimate(project, memory: memory).reason.contains("not installed"))
    check(missing.estimate(Project(), kind: "transcribe", memory: memory).reason.contains("not installed"))
    let transcription = Estimator(installed: { _ in true }, coversInstalled: { true }).estimate(Project(), kind: "transcribe", memory: memory)
    check(transcription.allowed && transcription.peak_high_gib == 6)
    // Automatic prefers 8-bit, and falls back to whichever model is installed.
    check(Estimator(installed: { _ in true }, coversInstalled: { true }).engine(for: Project()) == "metal-q8")
    check(Estimator(installed: { $0 == "metal-q4" }, coversInstalled: { true }).engine(for: Project()) == "metal-q4")
}

// MARK: The library

await test("a job keeps the cover as it was when queued") {
    let library = try temporaryLibrary()
    var queued: [String] = []
    library.onQueued = { queued.append($0) }
    let original = try library.save(song { $0.title = "First take"; $0.cover_preset = "Vintage soul" })
    let job = try library.createJob(JobRequest(kind: "generate", project: original))
    var revised = original
    revised.lyrics = "[Chorus]\nChanged words"; revised.style = "Jazz"
    try library.save(revised)
    let stored = try library.job(job.id).request.project
    check(stored.lyrics == original.lyrics && stored.style == "Soul" && stored.cover_preset == "Vintage soul")
    check(library.projects.first?.lyrics == revised.lyrics && queued == [job.id])
    // A fresh library reads the same files.
    let reopened = try Library(paths: library.paths)
    check(try reopened.job(job.id).request.project.lyrics == original.lyrics)
    check(reopened.projects.map(\.id) == [original.id])
}

await test("cancelling is final and keeps finished takes") {
    let library = try temporaryLibrary()
    var cancelled: [String] = []
    library.onCancelled = { cancelled.append($0) }
    let job = try library.createJob(JobRequest(kind: "generate", project: song()))
    let track = AudioTrack(name: "Take 1", audio: "finished.wav", duration: 1, waveform: [], seed: 1, abc: "", truncated: false)
    library.update(job.id) { $0.result = JobResult(tracks: [track]) }
    check(try library.cancelJob(job.id).status == "cancelled" && cancelled == [job.id])
    library.update(job.id, status: "complete") { $0.stage = "Complete" }
    library.update(job.id) { $0.stage = "Rendering acoustic detail" }
    let saved = try library.job(job.id)
    check(saved.status == "cancelled" && saved.stage == "Cancelled" && saved.tracks.first?.audio == "finished.wav")
}

await test("paths outside the library and bad ids are refused") {
    let library = try temporaryLibrary()
    checkThrows { _ = try library.resolve("../../outside.wav") }
    checkThrows({ var bad = song(); bad.id = "../../bad"; try library.save(bad) }, containing: "Invalid cover identifier")
    checkThrows { _ = try library.importAudio(URL(fileURLWithPath: "/tmp/bad.py")) }
    let source = try imported(library, "recording.wav")
    check(source.hasPrefix("imports/") && source.hasSuffix(".wav"))
    check(try library.resolve(source).lastPathComponent == URL(fileURLWithPath: source).lastPathComponent)
    checkThrows { try library.deleteProject("..%2F..%2Fbad") }
}

await test("recordings are checked before a job is queued") {
    let library = try temporaryLibrary()
    let source = try imported(library, "reference.wav")
    check(try library.createJob(JobRequest(kind: "transcribe", project: Project(), source: source)).status == "queued")
    checkThrows({ try library.createJob(JobRequest(kind: "transcribe", project: Project(), source: "../../outside.wav")) }, containing: "not found")
    let missing = song { $0.cot = "melody"; $0.abc = "K:C\nCDEF|"; $0.cover_source = "missing.wav"; $0.cover_job = "imported" }
    checkThrows({ try library.createJob(JobRequest(kind: "generate", project: missing)) }, containing: "not found")
}

await test("incomplete covers and unknown jobs are refused") {
    let library = try temporaryLibrary()
    checkThrows({ try library.createJob(JobRequest(kind: "generate", project: Project())) }, containing: "style and lyrics")
    checkThrows({ try library.createJob(JobRequest(kind: "generate", project: song { $0.abc = "X:1\nK:C\nCDEF"; $0.cot = "off" })) }, containing: "score")
    checkThrows { try library.createJob(JobRequest(kind: "separate", project: song())) }
    checkThrows({ try library.save(song { $0.tempo = 3 }) }, containing: "tempo")
    check(library.jobs.isEmpty)
}

await test("unsafe memory stores nothing") {
    let library = try temporaryLibrary(available: 2)
    check(!library.queuedEstimate(song()).allowed)
    checkThrows { try library.createJob(JobRequest(kind: "generate", project: song())) }
    check(library.jobs.isEmpty)
}

await test("a running job's memory counts as free for the job behind it") {
    let library = try temporaryLibrary(available: 8)
    library.reclaimable = { 10 }
    var project = song(); project.engine = "metal-q8"; project.max_tokens = 1500
    let result = library.queuedEstimate(project)
    check(result.allowed && result.memory.available_gib == 8 && result.queued_reclaim_gib == 10)
}

await test("the revision moves only when something is written") {
    let library = try temporaryLibrary()
    let first = library.revision
    check(library.revision == first)
    let saved = try library.save(song { $0.title = "First" })
    let job = try library.createJob(JobRequest(kind: "generate", project: saved))
    let second = library.revision
    check(second > first && library.state().jobs.map(\.id) == [job.id])
    library.update(job.id) { $0.stage = "Writing the new arrangement"; $0.phase = "compose"; $0.progress = 0.5 }
    check(library.revision > second && library.state().jobs.first?.progress == 0.5)
    let third = library.revision
    library.update(job.id) { $0.progress = 0.5 }
    check(library.revision == third, "an unchanged job must not move the revision")
}

await test("a stopped render with a saved song can resume") {
    let library = try temporaryLibrary()
    let job = try library.createJob(JobRequest(kind: "generate", project: song()))
    let take = library.folder(of: job.id).appendingPathComponent("take-1")
    try FileManager.default.createDirectory(at: take, withIntermediateDirectories: true)
    try Data("[1, 2, 3]".utf8).write(to: take.appendingPathComponent("semantic-prefix.json"))
    check(!(try library.job(job.id).resumable))
    library.update(job.id, status: "failed") { $0.stage = "Progress guard"; $0.error = "stalled" }
    check(try library.job(job.id).resumable)
    let stored = try String(contentsOf: library.folder(of: job.id).appendingPathComponent("job.json"), encoding: .utf8)
    check(!stored.contains("resumable"))
    // Resuming keeps the song: the words cannot change, how it is rendered can.
    var changed = song(); changed.lyrics = "Different song"
    checkThrows({ try library.createJob(JobRequest(kind: "generate", project: changed, resumeFrom: job.id)) }, containing: "Resume preserves")
    var rendering = song(); rendering.nar_chunk_frames = 512; rendering.ode_steps = 8; rendering.engine = "metal-q8"
    check(try library.createJob(JobRequest(kind: "generate", project: rendering, resumeFrom: job.id)).status == "queued")
}

await test("a take can be extended or rendered again from its saved song") {
    let library = try temporaryLibrary()
    var project = song(); project.takes = 2; project.max_tokens = 1500
    let job = try library.createJob(JobRequest(kind: "generate", project: project))
    let second = library.folder(of: job.id).appendingPathComponent("take-2")
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try Data("[\(Array(repeating: "7", count: 40).joined(separator: ", "))]".utf8).write(to: second.appendingPathComponent("semantic-prefix.json"))
    library.update(job.id, status: "complete") { _ in }
    // Writing on may use another seed, guidance or quality, but keeps the words and a longer length.
    var longer = project; longer.takes = 1; longer.max_tokens = 9000; longer.seed = 77; longer.cfg_scale = 1.5; longer.engine = "metal-q8"
    check(try library.createJob(JobRequest(kind: "generate", project: longer, resumeFrom: job.id, take: 2, continuing: true)).status == "queued")
    var reworded = longer; reworded.lyrics = "Other words"
    checkThrows({ try library.createJob(JobRequest(kind: "generate", project: reworded, resumeFrom: job.id, take: 2, continuing: true)) }, containing: "Extending keeps")
    var short = longer; short.max_tokens = 32
    checkThrows({ try library.createJob(JobRequest(kind: "generate", project: short, resumeFrom: job.id, take: 2, continuing: true)) }, containing: "longer than the take")
    // Rendering the second take again draws on its own seed, one past the job's.
    var again = project; again.takes = 1; again.engine = "metal-q8"; again.seed = project.seed + 1
    check(try library.createJob(JobRequest(kind: "generate", project: again, resumeFrom: job.id, take: 2)).status == "queued")
    var reseeded = again; reseeded.seed = project.seed
    checkThrows({ try library.createJob(JobRequest(kind: "generate", project: reseeded, resumeFrom: job.id, take: 2)) }, containing: "Resume preserves")
    checkThrows({ try library.createJob(JobRequest(kind: "generate", project: again, resumeFrom: job.id, take: 3)) }, containing: "no saved song")
    checkThrows({ try JobRequest(kind: "generate", project: again, continuing: true).validate() }, containing: "Choose the take")
}

await test("deleting a cover removes its takes and its unshared recording") {
    let library = try temporaryLibrary()
    let source = try imported(library)
    let cover = try library.save(song { $0.cover_source = source; $0.cover_job = "t"; $0.abc = "K:C\nCDEF|"; $0.cot = "melody" })
    let twin = try library.save(song { $0.cover_source = source })
    let job = try library.createJob(JobRequest(kind: "generate", project: cover))
    let other = try library.createJob(JobRequest(kind: "generate", project: song()))
    checkThrows({ try library.deleteProject(cover.id) }, containing: "Cancel")
    checkThrows({ try library.deleteJob(job.id) }, containing: "Cancel")
    try library.cancelJob(job.id)
    check(try library.deleteProject(cover.id) == 1)
    check(!FileManager.default.fileExists(atPath: library.folder(of: job.id).path))
    check(FileManager.default.fileExists(atPath: library.folder(of: other.id).path))
    // The recording stays while another cover still uses it.
    check(FileManager.default.fileExists(atPath: library.data.appendingPathComponent(source).path))
    try library.deleteProject(twin.id)
    check(!FileManager.default.fileExists(atPath: library.data.appendingPathComponent(source).path))
    checkThrows { try library.deleteProject(twin.id) }
    try library.cancelJob(other.id)
    try library.deleteJob(other.id)
    check(library.jobs.isEmpty)
}

await test("jobs running when the app closed are marked interrupted") {
    let library = try temporaryLibrary()
    let job = try library.createJob(JobRequest(kind: "generate", project: song()))
    library.update(job.id, status: "running") { $0.engine_pid = 4242; $0.engine_started = 99 }
    let engines = library.markInterrupted()
    check(try library.job(job.id).status == "failed" && (try library.job(job.id).stage) == "Interrupted")
    check(engines.count == 1 && engines[0].pid == 4242 && engines[0].started == 99)
    check(try library.job(job.id).engine_pid == nil)
}

await test("a recording is listened to once, however many ask") {
    let library = try temporaryLibrary()
    let source = try imported(library)
    let first = try library.createJob(JobRequest(kind: "transcribe", project: Project(), source: source))
    let second = try library.createJob(JobRequest(kind: "transcribe", project: Project(), source: source))
    check(first.id == second.id && library.jobs.count == 1)
    try library.cancelJob(first.id)
    check(try library.createJob(JobRequest(kind: "transcribe", project: Project(), source: source)).id != first.id)
}

await test("a replaced recording is removed once nothing uses it") {
    let library = try temporaryLibrary()
    let old = try imported(library), kept = try imported(library)
    let cover = try library.save(song { $0.cover_source = kept })
    library.releaseImport(kept)
    check(FileManager.default.fileExists(atPath: library.data.appendingPathComponent(kept).path))
    library.releaseImport(old)
    check(!FileManager.default.fileExists(atPath: library.data.appendingPathComponent(old).path))
    _ = try library.createJob(JobRequest(kind: "transcribe", project: cover, source: kept))
    var moved = cover; moved.cover_source = ""
    try library.save(moved)
    library.releaseImport(kept)
    check(FileManager.default.fileExists(atPath: library.data.appendingPathComponent(kept).path), "a job still uses it")
}

await test("live progress is shown at once and saved now and then") {
    let library = try temporaryLibrary()
    let job = try library.createJob(JobRequest(kind: "generate", project: song()))
    let file = library.folder(of: job.id).appendingPathComponent("job.json")
    nonisolated(unsafe) var told = 0
    library.onChanged = { told += 1 }
    library.update(job.id, live: true) { $0.tokens = 25; $0.phase = "compose" }
    library.update(job.id, live: true) { $0.tokens = 50 }
    check(try library.job(job.id).tokens == 50 && told == 2)
    check(try library.job(job.id).phase_started_at != nil)
    check((try String(contentsOf: file, encoding: .utf8)).contains("\"tokens\" : 25"), "the first change is written, the next waits")
    library.update(job.id, status: "complete")
    check((try String(contentsOf: file, encoding: .utf8)).contains("\"tokens\" : 50"))
}

await test("covers written by the Python service still load") {
    let library = try temporaryLibrary()
    let id = UUID().uuidString.lowercased()
    let job = """
    {"id": "\(id)", "status": "complete", "stage": "Complete", "created_at": "2026-10-01T10:00:00.123456+00:00",
     "request": {"kind": "generate", "project": {"title": "Old", "style": "Soul", "lyrics": "Hi", "engine": "torch"}, "source": "", "resume_from": ""},
     "result": {"tracks": [{"name": "Take 1", "audio": "jobs/x/take-1/audio.wav", "flac": "jobs/x/take-1/audio.flac", "duration": 10.0,
                "waveform": [0.1], "seed": 1, "abc": "", "truncated": false}]},
     "error": "", "tokens": 0, "take": 1, "progress": null, "estimate": {"engine": "metal-q8", "unknown": 1}}
    """
    try FileManager.default.createDirectory(at: library.folder(of: id), withIntermediateDirectories: true)
    try Data(job.utf8).write(to: library.folder(of: id).appendingPathComponent("job.json"))
    let reopened = try Library(paths: library.paths)
    let loaded = try reopened.job(id)
    check(loaded.tracks.count == 1 && loaded.request.project.engine == "auto" && loaded.request.project.cot == "full")
    check(timestamp().matchesPattern(#"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}\+00:00$"#), timestamp())
}

// MARK: Rendering

await test("tempo scales the score's marks and leaves the notes") {
    let score = "X:1\nM:4/4\nL:1/16\nQ:1/4=125\nK:F\nV: Vocal\nz6c2c2d2a2f2|\n"
    check(MusicRender.retime(score, 1.0) == score)
    check(MusicRender.retime(score, 0.8) == score.replacingOccurrences(of: "Q:1/4=125", with: "Q:1/4=100"))
    check(MusicRender.retime("Q:120\nCDEF|", 1.25) == "Q:150\nCDEF|")
    check(MusicRender.retime("Q:1/4=40\nCDEF|", 0.5).contains("Q:1/4=30"))
}

await test("song tokens load from both layouts the engine writes") {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try Data("[1, 2, 3]".utf8).write(to: file)
    check(try MusicRender.semanticArtifact(file).0 == [1, 2, 3])
    let hex = Data("[1,2,3]".utf8).map { String(format: "%02x", $0) }.joined()
    try Data(#"{"payload_hex": "\#(hex)", "meta": {"truncated": "true"}}"#.utf8).write(to: file)
    let (codes, meta) = try MusicRender.semanticArtifact(file)
    check(codes == [1, 2, 3] && meta["truncated"] as? String == "true")
    try Data(#"[1, 2.5]"#.utf8).write(to: file)
    checkThrows { _ = try MusicRender.semanticArtifact(file) }
}

await test("engine log lines become progress") {
    var project = Project(); project.max_tokens = 1000; project.ode_steps = 32
    func job(after line: String) -> Job? {
        guard let change = MusicRender.progress(in: line, project: project) else { return nil }
        var job = Job(id: "x", status: "running", stage: "", created_at: "", request: JobRequest(kind: "generate", project: project))
        change(&job)
        return job
    }
    check(job(after: "moonwire.progress.semantic 250")?.progress == 0.25)
    check(job(after: "moonwire.progress.semantic 250")?.tokens == 250)
    check(job(after: "yue2.ar.generate.emitted_tokens = 77")?.tokens == 77)
    check(job(after: "moonwire.progress.flow 16")?.progress == 0.5)
    check(job(after: "moonwire.progress.vae 750")?.stage == "Decoding stereo audio")
    check(job(after: "moonwire.progress.vae 750")?.progress == 0.75)
    check(job(after: "loading tensors") == nil)
}

await test("finished audio is checked, kept losslessly and drawn") {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let wav = folder.appendingPathComponent("audio.wav")
    try writeTone(wav, seconds: 2, rate: 48000, channels: 2, silentFirstHalf: true)
    let finished = try MusicRender.finish(wav, lossless: folder.appendingPathComponent("audio.flac"))
    check(abs(finished.duration - 2) < 0.001 && finished.waveform.count == 300)
    check(finished.waveform[0] == 0 && finished.waveform[299] > 0.4, "\(finished.waveform.prefix(3)) … \(finished.waveform.suffix(3))")
    let flac = try AVAudioFile(forReading: folder.appendingPathComponent("audio.flac"))
    check(flac.length == 96000 && flac.fileFormat.channelCount == 2)
    try writeTone(wav, seconds: 1, rate: 44100)
    checkThrows({ _ = try MusicRender.finish(wav, lossless: folder.appendingPathComponent("audio.flac")) }, containing: "invalid audio")
}

// MARK: Processes

await test("the engine lock excludes a second holder until released") {
    let library = try temporaryLibrary()
    let runner = JobRunner(library: library)
    library.onQueued = { _ in }
    let job = try library.createJob(JobRequest(kind: "generate", project: song()))
    guard let lease = runner.acquireEngineLock(job.id) else { check(false, "no lease"); return }
    let other = open(library.paths.engineLock.path, O_RDWR)
    check(flock(other, LOCK_EX | LOCK_NB) != 0)
    flock(lease, LOCK_UN); close(lease)
    check(flock(other, LOCK_EX | LOCK_NB) == 0)
    // A job cancelled while it waits never takes the lock.
    let waiting = try library.createJob(JobRequest(kind: "generate", project: song()))
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Int32? = 0
    DispatchQueue.global().async { result = runner.acquireEngineLock(waiting.id); done.signal() }
    for _ in 0..<30 where (try? library.job(waiting.id))?.stage != "Waiting for another local music job" { usleep(100_000) }
    check(try library.job(waiting.id).stage == "Waiting for another local music job")
    try library.cancelJob(waiting.id)
    check(done.wait(timeout: .now() + 3) == .success && result == nil)
    close(other)
}

await test("stopping an engine stops everything it started") {
    let process = try ChildProcess.spawn("/bin/sh", ["-c", "trap '' TERM; (trap '' TERM; sleep 60) & echo started; sleep 60"],
                                         environment: ["PATH": "/bin:/usr/bin"])
    var first = ""
    let reading = Thread { process.readLines { line in if first.isEmpty { first = line } } }
    reading.start()
    for _ in 0..<50 where Machine.group(process.pid).count < 2 { usleep(50_000) }
    check(Machine.group(process.pid).count >= 2, "the group should hold the shell and its child")
    check(Machine.groupFootprint(process.pid) > 0)
    let started = Date()
    try process.stop()
    check(Machine.group(process.pid).isEmpty && Date().timeIntervalSince(started) < 8)
    check(process.wait() != 0)
}

await test("the kernel's pressure decides when memory is short") {
    var calm = memory; calm.available_gib = 2; calm.pressure = 1
    check(!MemoryGuard.strained(calm), "macOS can reclaim more than free plus inactive")
    calm.available_gib = 1
    check(MemoryGuard.strained(calm))
    var warned = memory; warned.available_gib = 2.5; warned.pressure = 2
    check(MemoryGuard.strained(warned))
    var critical = memory; critical.pressure = 4
    check(MemoryGuard.strained(critical))
    var stalled = MemoryGuard(limit: 21.6)
    check(stalled.check(used: 3, memory: memory, silence: 300, allowance: 600) == nil, "loading may stay quiet longer")
}

await test("the guards stop runaway memory and a stalled engine") {
    var guardian = MemoryGuard(limit: 21.6)
    check(guardian.check(used: 3, memory: memory, silence: 10) == nil)
    let over = guardian.check(used: 23, memory: memory, silence: nil)
    check(over?.stage == "Memory guard" && over?.message.contains("23.0 GB") == true && guardian.peak == 23)
    var pressured = MemoryGuard(limit: 21.6)
    var low = memory; low.available_gib = 2
    check(pressured.check(used: 3, memory: low, silence: nil) == nil && pressured.check(used: 3, memory: low, silence: nil) == nil)
    check(pressured.check(used: 3, memory: low, silence: nil)?.stage == "Memory guard")
    var stalled = MemoryGuard(limit: 21.6)
    let stopped = stalled.check(used: 3, memory: memory, silence: 200)
    check(stopped?.stage == "Progress guard" && stopped?.message.contains("no progress") == true)
}

await test("this Mac's memory and cores can be read") {
    let now = Machine.memory()
    check(now.total_gib > 1 && now.available_gib > 0 && now.available_gib <= now.total_gib)
    check(Machine.footprint(getpid()).map { $0 > 0 } == true)
    check((4...12).contains(Machine.performanceCores))
}

// MARK: Agents

let score = "X:1\nM:4/4\nL:1/16\nQ:1/4=120\nK:C\nV: Vocal\nc4d4e4f4|\n"

func agent(_ library: Library) -> (rpc: (String, [String: Any]) async -> [String: Any], tool: (String, [String: Any]) async -> (Any, Bool)) {
    var tools = AgentTools(library: library)
    tools.details = { _, name in SongLookup.details(duration: 200, tags: [:], name: name) }
    let rpc: (String, [String: Any]) async -> [String: Any] = { method, params in
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let reply = await tools.respond(to: body)
        return reply.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    let tool: (String, [String: Any]) async -> (Any, Bool) = { name, arguments in
        let result = await rpc("tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any] ?? [:]
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let failed = result["isError"] as? Bool ?? false
        return (failed ? text : (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? text, failed)
    }
    return (rpc, tool)
}

await test("the agent handshake lists tools and ignores notifications") {
    let library = try temporaryLibrary()
    let (rpc, _) = agent(library)
    let hello = await rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])["result"] as? [String: Any]
    check(hello?["protocolVersion"] as? String == "2025-06-18" && (hello?["serverInfo"] as? [String: Any])?["name"] as? String == "moonshift")
    let notification = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
    expect(await AgentTools(library: library).respond(to: notification).status == 202)
    let names = ((await rpc("tools/list", [:])["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    check(Set(["list_covers", "get_cover", "update_cover", "create_take", "transcribe", "get_job"]).isSubset(of: Set(names)))
    expect((await rpc("nonsense", [:])["error"] as? [String: Any])?["code"] as? Int == -32601)
}

await test("an agent edits the score and renders the revision") {
    let library = try temporaryLibrary()
    let (_, tool) = agent(library)
    let recording = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
    let file = recording.appendingPathComponent("Singer - Home.mp3")
    try Data("audio".utf8).write(to: file)
    let (created, failed) = await tool("create_cover", ["audio_path": file.path, "lyrics": "[Verse]\nComing home", "style": "Soul"])
    let cover = created as? [String: Any] ?? [:]
    check(!failed && cover["title"] as? String == "Home" && cover["score_source"] as? String == "none", "\(created)")
    check((cover["note"] as? String)?.contains("transcribe") == true)
    let id = cover["cover_id"] as? String ?? ""
    expect(((await tool("list_covers", [:])).0 as? [[String: Any]])?.compactMap { $0["cover_id"] as? String } == [id])

    // No score yet: rendering is refused with an instruction, not a crash.
    let refused = await tool("create_take", ["cover_id": id])
    check(refused.1 && (refused.0 as? String)?.contains("transcribe") == true)
    let listening = (await tool("transcribe", ["cover_id": id])).0 as? [String: Any] ?? [:]
    check(listening["kind"] as? String == "transcription" && listening["status"] as? String == "queued")
    library.update(listening["job_id"] as? String ?? "", status: "complete") {
        $0.result = JobResult(abc: score, full_abc: score.replacingOccurrences(of: "c4", with: "\"C\"c4"))
    }
    expect(((await tool("transcribe", ["cover_id": id])).0 as? [String: Any])?["note"] as? String == "This recording is already transcribed.")

    let heard = (await tool("get_cover", ["cover_id": id])).0 as? [String: Any] ?? [:]
    check(heard["score"] as? String == score && heard["score_source"] as? String == "transcription")
    let harmony = (await tool("update_cover", ["cover_id": id, "keep": "melody_and_harmony"])).0 as? [String: Any] ?? [:]
    check((harmony["score"] as? String)?.components(separatedBy: "\"C\"").count == 2)

    let revised = score.replacingOccurrences(of: "c4d4e4f4", with: "c4e4g4c'4").replacingOccurrences(of: "Q:1/4=120", with: "Q:1/4=96")
    let (editedValue, editFailed) = await tool("update_cover", ["cover_id": id, "score": revised, "lyrics": "[Verse]\nGoing home", "tempo": 0.9,
                                                               "length_seconds": 60, "quality": "high"])
    let edited = editedValue as? [String: Any] ?? [:]
    check(!editFailed && edited["score"] as? String == revised && edited["score_source"] as? String == "edited", "\(editedValue)")
    check(edited["tempo"] as? Double == 0.9 && edited["length_seconds"] as? Double == 60 && edited["quality"] as? String == "high")

    let (takeValue, takeFailed) = await tool("create_take", ["cover_id": id])
    let take = takeValue as? [String: Any] ?? [:]
    check(!takeFailed && take["kind"] as? String == "take" && take["status"] as? String == "queued", "\(takeValue)")
    let queued = try library.job(take["job_id"] as? String ?? "").request.project
    check(queued.abc == revised && queued.score_edited && queued.lyrics == "[Verse]\nGoing home" && queued.max_tokens == 1500)
    // While it renders, the cover cannot be changed underneath it.
    expect(await tool("update_cover", ["cover_id": id, "style": "Jazz"]).1)
    expect(((await tool("cancel_job", ["job_id": take["job_id"] ?? ""])).0 as? [String: Any])?["status"] as? String == "cancelled")
    // Clearing the score returns to what was heard in the recording.
    expect(((await tool("update_cover", ["cover_id": id, "score": ""])).0 as? [String: Any])?["score_source"] as? String == "transcription")
}

await test("bad agent requests come back as readable tool errors") {
    let library = try temporaryLibrary()
    let (_, tool) = agent(library)
    expect(await tool("get_cover", ["cover_id": "../../etc"]).1)
    expect((await tool("get_cover", [:])).0 as? String == "Missing argument: cover_id")
    expect(await tool("create_cover", ["audio_path": "/tmp/notes.txt"]).1)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    try Data("audio".utf8).write(to: file)
    let cover = (await tool("create_cover", ["audio_path": file.path])).0 as? [String: Any] ?? [:]
    let (message, failed) = await tool("update_cover", ["cover_id": cover["cover_id"] ?? "", "tempo": 9])
    check(failed && (message as? String)?.contains("tempo") == true, "\(message)")
    expect(await tool("no_such_tool", [:]).1)
}

await test("the agent endpoint answers on the loopback address only") {
    let library = try temporaryLibrary()
    let tools = AgentTools(library: library)
    let port = 18766 + Int.random(in: 0..<1000)
    let token = "0123456789abcdef0123456789abcdef"
    let server = try LoopbackServer(port: port) { method, path, headers, body in
        guard path == "/mcp" else { return (404, [:], nil) }
        guard method == "POST" else { return (405, ["Allow": "POST"], nil) }
        guard LoopbackServer.authorized(headers, token: token) else { return (401, [:], nil) }
        let reply = await tools.respond(to: body)
        return (reply.status, [:], reply.body)
    }
    await withCheckedContinuation { ready in server.start { _ in ready.resume() } }
    defer { server.stop() }
    func send(_ method: String, origin: String? = nil, type: String = "application/json", bearer: String? = token,
              body: [String: Any]? = nil) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = method
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let ping: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "ping"]
    let (status, reply) = try await send("POST", body: ping)
    check(status == 200 && reply?["id"] as? Int == 7)
    expect(try await send("GET").0 == 405)
    expect(try await send("POST", origin: "https://example.com", body: ping).0 == 403)
    // A page on any local port is still a page.
    expect(try await send("POST", origin: "http://localhost:3000", body: ping).0 == 403)
    expect(try await send("POST", type: "text/plain", body: ping).0 == 415)
    expect(try await send("POST", bearer: nil, body: ping).0 == 401)
    expect(try await send("POST", bearer: String(token.reversed()), body: ping).0 == 401)
    check(LoopbackServer.Request(method: "POST", path: "/mcp", headers: ["host": "attacker.example:8766"], body: Data()).isLocal == false)
    check(LoopbackServer.Request(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:8766"], body: Data()).isLocal)
    check(LoopbackServer.Request(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:8766", "sec-fetch-site": "same-site"], body: Data()).isLocal == false)
}

await test("a client that never finishes its request is disconnected") {
    let port = 18766 + Int.random(in: 1000..<2000)
    let server = try LoopbackServer(port: port) { _, _, _, _ in (200, [:], nil) }
    await withCheckedContinuation { ready in server.start { _ in ready.resume() } }
    defer { server.stop() }
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    check(connected == 0)
    _ = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n".withCString { send(socket, $0, strlen($0), 0) }
    var timeout = timeval(tv_sec: 15, tv_usec: 0)
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let started = Date()
    var byte: UInt8 = 0
    check(recv(socket, &byte, 1, 0) <= 0 && Date().timeIntervalSince(started) < 14, "the server should close the connection")
}

// MARK: Updates

await test("only a later version is offered") {
    check(UpdateFeed.isNewer("1.3.0", than: "1.2.0") && UpdateFeed.isNewer("1.10.0", than: "1.9.2") && UpdateFeed.isNewer("2", than: "1.9"))
    check(!UpdateFeed.isNewer("1.2.0", than: "1.2.0") && !UpdateFeed.isNewer("1.2", than: "1.2.0") && !UpdateFeed.isNewer("1.1.9", than: "1.2.0"))
    let json = #"{"tag_name": "v1.3.0", "html_url": "https://github.com/x", "body": "Notes", "assets": [{"name": "notes.txt", "browser_download_url": "a"}, {"name": "Moonshift-1.3.0.dmg", "browser_download_url": "b", "size": 3}]}"#
    let release = try JSONDecoder().decode(UpdateFeed.Release.self, from: Data(json.utf8))
    check(release.version == "1.3.0" && release.image?.browser_download_url == "b")
}

await test("an update must be Moonshift, signed by its developer and notarized") {
    // Apple's own tools are signed and notarized, but are not Moonshift.
    checkThrows({ try UpdateFeed.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app")) }, containing: "not signed and notarized")
    checkThrows { try UpdateFeed.verify(FileManager.default.temporaryDirectory.appendingPathComponent("missing.app")) }
}

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
