import AVFoundation
import Foundation

/// A small test harness: the engine builds with plain `swiftc`, without a test target.
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var current = ""

func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    do {
        if try condition() { return }
        print("  ✗ \(current): \(file):\(line) \(message)")
    } catch {
        print("  ✗ \(current): \(file):\(line) threw \(error.localizedDescription) \(message)")
    }
    failures += 1
}

/// `check` for conditions that await: they are worked out before the call.
func expect(_ condition: Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    check(condition, message, file: file, line: line)
}

func checkThrows(_ body: () throws -> Void, containing text: String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    do {
        try body()
        print("  ✗ \(current): \(file):\(line) did not throw")
        failures += 1
    } catch {
        if !text.isEmpty, !error.localizedDescription.contains(text) {
            print("  ✗ \(current): \(file):\(line) threw “\(error.localizedDescription)”, expected “\(text)”")
            failures += 1
        }
    }
}

func test(_ name: String, _ body: () async throws -> Void) async {
    current = name
    do {
        try await body()
    } catch {
        print("  ✗ \(name): threw \(error.localizedDescription)")
        failures += 1
    }
}

/// A library in a fresh folder, with memory and installed models fixed so tests do not depend on this Mac.
func temporaryLibrary(available: Double = 32, installed: Bool = true) throws -> Library {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moonshift-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let library = try Library(paths: Paths(root: folder, code: folder))
    library.memory = { MemoryState(total_gib: 36, available_gib: available, free_gib: 2, limit_gib: 21.6, reserve_gib: 6) }
    library.estimator = Estimator(installed: { _ in installed }, coversInstalled: { installed })
    return library
}

func song(_ change: (inout Project) -> Void = { _ in }) -> Project {
    var project = Project()
    project.style = "Soul"; project.lyrics = "[Chorus]\nComing home"; project.engine = "metal-q4"
    change(&project)
    return project
}

/// Writes a small file into the library's data folder and returns its relative path.
func imported(_ library: Library, _ name: String = "song.wav") throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
    try Data("audio".utf8).write(to: file)
    return try library.importAudio(file)
}

/// A sine tone as a 16-bit WAV, optionally silent for its first half.
func writeTone(_ url: URL, seconds: Double, rate: Double = 44100, channels: Int = 1, silentFirstHalf: Bool = false) throws {
    try? FileManager.default.removeItem(at: url)
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                          AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16])
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<channels {
        for index in 0..<Int(frames) {
            let silent = silentFirstHalf && index < Int(frames) / 2
            buffer.floatChannelData![channel][index] = silent ? 0 : Float(0.5 * sin(2 * Double.pi * 440 * Double(index) / rate))
        }
    }
    try file.write(from: buffer)
}
