# Third-party models and runtimes

Moonshift's own application code is licensed under the [GNU General Public
License, version 3 or later](LICENSE). That license does not relicense
third-party code, model weights, tokenizers, or assets.
Setup downloads these separately; none are included in this Git repository.
Release builds of the app include uv and a compiled copy of the audio.cpp runtime.
Their original licenses and notices remain alongside the downloaded files.

| Component | Upstream / terms |
| --- | --- |
| YuE2 generation and VAE models | [Model card](https://huggingface.co/m-a-p/YuE2-3B), [model-weight terms](https://github.com/multimodal-art-projection/YuE/blob/main/MODEL_LICENSE): CC BY-NC 4.0 with additional creator permission in current upstream terms |
| audio.cpp Metal runtime | [Repository](https://github.com/0xShug0/audio.cpp), [Apache 2.0 license](https://github.com/0xShug0/audio.cpp/blob/main/LICENSE); includes separately licensed components such as GGML |
| Quantized YuE2 conversions | [Conversion card](https://huggingface.co/audio-cpp/Yue2-3B-GGUF); original model-weight terms apply |
| SheetSage2 | [Model card](https://huggingface.co/m-a-p/SheetSage2), [license](https://huggingface.co/m-a-p/SheetSage2/blob/main/LICENSE), [third-party notices](https://huggingface.co/m-a-p/SheetSage2/blob/main/THIRD_PARTY_NOTICES.md) |
| MERT-v2-FullSong | [Model card](https://huggingface.co/m-a-p/MERT-v2-FullSong), [license](https://huggingface.co/m-a-p/MERT-v2-FullSong/blob/main/LICENSE) |
| uv | [Repository](https://github.com/astral-sh/uv), MIT or Apache 2.0; included in release builds to create the Python environments |
| FFmpeg | [Project and license](https://ffmpeg.org/legal.html); a static build is installed during setup through [imageio-ffmpeg](https://github.com/imageio/imageio-ffmpeg) (BSD 2-Clause) to read recordings |
| Optional ShazamIO song recognition | [Source and MIT license](https://github.com/shazamio/ShazamIO); unofficial Shazam interface, used only for opt-in online identification |
| Optional LRCLIB lyrics search | [API documentation](https://lrclib.net/docs), [server source](https://github.com/tranxuanthang/lrclib); retrieved lyrics retain their original rights and source provenance |

Python packages installed by the setup scripts retain their respective licenses.
YuE2's current upstream permission for personal creators and monetized outputs
is separate from its restrictions on commercial use of the weights by companies.
Consult the linked full terms and those shipped with your installed versions.
Licensing Moonshift's code under the GPL does not grant commercial rights to
the models it uses.
