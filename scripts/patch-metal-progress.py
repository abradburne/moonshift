"""Idempotent progress and chunking hooks for the pinned audio.cpp runtime.

The log keys keep the `moonwire.` prefix: Moonwire shares this runtime checkout.
"""
import os
from pathlib import Path

home = Path(os.environ.get("MOONSHIFT_HOME") or Path(__file__).resolve().parent.parent)
source = home / ".runtime/audio.cpp/src/models/yue2/ar_runtime.cpp"
text = source.read_text()
if "moonwire.progress.semantic" not in text:
    old = "            emitted.push_back(token);\n"
    new = old + '''            if (emitted.size() % 25 == 0) {
                engine::debug::timing_log_scalar(
                    compact_semantic ? "moonwire.progress.semantic" : "moonwire.progress.abc", emitted.size());
            }
'''
    if text.count(old) != 2:
        raise RuntimeError("audio.cpp changed; review the progress hook before rebuilding.")
    source.write_text(text.replace(old, new))

root = source.parents[3]

def replace_once(path, marker, old, new):
    text = path.read_text()
    if marker not in text:
        if text.count(old) != 1:
            raise RuntimeError(f"audio.cpp changed: review {path.name} before rebuilding.")
        path.write_text(text.replace(old, new))

replace_once(root / "include/engine/models/yue2/types.h", "nar_chunk_frames", "    int64_t context = kContextTokens;", "    int64_t context = kContextTokens;\n    int64_t nar_chunk_frames = 0;")
replace_once(root / "src/models/yue2/request.cpp", "nar_chunk_frames", "    auto apply_sampling =", '''    out.generation.nar_chunk_frames = runtime::parse_positive_i64_option(
        options, {"nar_chunk_frames"}, 0);
    if (out.generation.nar_chunk_frames < 0 || out.generation.nar_chunk_frames > 16000) {
        throw std::runtime_error("nar_chunk_frames must be in [0,16000]");
    }
    auto apply_sampling =''')
replace_once(root / "src/models/yue2/pipeline.cpp", "generation.nar_chunk_frames", "            generation.context);", '''            generation.nar_chunk_frames > 0 ?
                std::min(generation.context, static_cast<int64_t>(semantic.plan.prefix.size()) + 2 * generation.nar_chunk_frames + 3) :
                generation.context);''')
replace_once(root / "src/models/yue2/nar_runtime.cpp", "moonwire.progress.flow", "            state[i] -= second[i] * dt;\n            }\n", '''            state[i] -= second[i] * dt;
            }
            engine::debug::timing_log_scalar("moonwire.progress.flow", step + 1);
''')
