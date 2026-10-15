import Foundation

/// Where things live. `root` holds everything installed or created: models,
/// environments, the music engine, and covers. `code` holds the transcription
/// helper's Python package and the setup scripts. A checkout uses one folder
/// for both; the packaged app keeps its code inside the bundle.
struct Paths {
    /// Resolved, so paths built from it compare equal however the folder was reached.
    let root: URL
    let code: URL
    /// Tools shipped inside the packaged app: the music engine and uv.
    let helpers: URL?

    init(root: URL, code: URL, helpers: URL? = nil) {
        self.root = root.resolvingSymlinksInPath()
        self.code = code
        self.helpers = helpers
    }

    var data: URL { root.appendingPathComponent("data") }
    var models: URL { root.appendingPathComponent(".models") }
    var gguf: URL { models.appendingPathComponent("YuE2-GGUF") }
    var engineLock: URL { root.appendingPathComponent(".runtime/model-job.lock") }
    var temporary: URL { root.appendingPathComponent(".cache/tmp") }
    var coversPython: URL { root.appendingPathComponent(".covers-venv/bin/python") }
    var lookupPython: URL { root.appendingPathComponent(".lookup-venv/bin/python") }

    /// The packaged app ships the music engine prebuilt; a checkout builds its own.
    var engine: URL {
        if let bundled = helpers?.appendingPathComponent("audiocpp_cli"), FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return root.appendingPathComponent(".runtime/audio.cpp/build/macos-metal-release/bin/audiocpp_cli")
    }

    /// The FFmpeg setup installed, or one already on the PATH.
    var ffmpeg: URL? {
        let candidates = [root.appendingPathComponent(".runtime/bin/ffmpeg").path, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func installed(_ engine: String) -> Bool {
        let weights = (Quality(rawValue: engine) ?? .high).weights
        let sidecars = ["yue2-model-config.json", "yue2-generation-config.json", "yue2-qwen.tiktoken", "yue2-vae-config.json"]
        return FileManager.default.isExecutableFile(atPath: self.engine.path)
            && ([gguf.appendingPathComponent(weights), gguf.appendingPathComponent("yue2-vae-f16.gguf")]
                + sidecars.map { gguf.appendingPathComponent("sidecars/" + $0) }).allSatisfy(exists)
    }

    var coversInstalled: Bool {
        [coversPython, models.appendingPathComponent("SheetSage2/model.safetensors"),
         models.appendingPathComponent("SheetSage2/modeling_sheetsage2.py"),
         models.appendingPathComponent("MERT-v2-FullSong/model.safetensors")].allSatisfy(exists)
    }

    var lookupInstalled: Bool {
        guard exists(lookupPython) else { return false }
        let libraries = root.appendingPathComponent(".lookup-venv/lib")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: libraries.path)) ?? []
        return versions.contains { $0.hasPrefix("python") && exists(libraries.appendingPathComponent("\($0)/site-packages/shazamio/api.py")) }
    }

    /// Something has been installed here, so the app can open its workspace rather than setup.
    var anythingInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: coversPython.path) || Quality.allCases.contains { installed($0.rawValue) }
    }

    /// The environment model processes run in: every cache inside the library folder.
    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MOONSHIFT_HOME"] = root.path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HOME"] = root.appendingPathComponent(".cache/huggingface").path
        environment["HF_MODULES_CACHE"] = root.appendingPathComponent(".cache/huggingface/modules").path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent(".cache").path
        environment["TORCH_HOME"] = root.appendingPathComponent(".cache/torch").path
        environment["TMPDIR"] = temporary.path
        environment["TOKENIZERS_PARALLELISM"] = "false"
        // Nothing is written beside the code: inside the app it is sealed by the signature.
        if code.standardizedFileURL != root.standardizedFileURL { environment["PYTHONDONTWRITEBYTECODE"] = "1" }
        // The transcription model looks for FFmpeg on the PATH; setup installs one here.
        environment["PATH"] = [root.appendingPathComponent(".runtime/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
                               environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        return environment
    }
}
