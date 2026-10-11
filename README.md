# Moonshift

A native macOS app that turns a song into a cover in a different style. It
listens for the melody, then performs the song anew with the sound and singer
you choose. Transcription and music generation run on your Mac.

## Open it

Download **Moonshift** from the [latest release](https://github.com/abradburne/moonshift/releases/latest),
open the disk image and drag it to Applications. It needs Apple Silicon and
macOS 14 or later, and nothing else installed. The first launch downloads the
local models (about 7 GB) with one click. Models and covers are kept in
`~/Library/Application Support/Moonshift`, or a folder you choose at that point.

From a checkout, double-click **[Moonshift.command](Moonshift.command)** instead;
that build keeps everything in the checkout folder.

1. **Song.** Drop in WAV, FLAC, MP3, AIFF or M4A audio, up to 15 minutes or
   512 MB. Paste the lyrics, import a TXT, SRT, LRC or WebVTT file, or use
   *Find Online*. Subtitle timings and markup are removed on import.
2. **Style.** Pick a preset or describe the sound, choose a singer, and decide
   whether to keep only the melody or the original harmony too. Your own
   presets live beside the built-in ones.
3. **Create.** Choose a length and quality, then *Create Cover*. Moonshift
   listens to the song once, writes a new arrangement, and renders it. Each
   take keeps the settings it was made with; play, export (WAV or FLAC), reuse
   its style, or delete it.

Covers are saved as you work and listed in the sidebar. You can open another
cover while one is being created; quitting stops a cover in progress.

Good to know:

- A length is a ceiling. A shorter song ends sooner; a song longer than the
  limit is cut off, and the take says so.
- Every take uses a new random seed, so the same settings give a new performance.
- If rendering stops partway, the song already written is kept. *Resume
  Rendering* finishes it; *in Sections* is steadier on long songs.
- Memory and progress guards stop a job that would exhaust memory or has stalled.
- Singers are new voices shaped by a description. They do not clone a recording.

## Optional online lookup

Off until you turn it on. *Find Online* sends the song's title and artist to
LRCLIB. Naming an unrecognised recording sends a short audio fingerprint to
Shazam through ShazamIO, an unofficial interface that may change. Matches can
be wrong, so lyrics are shown for review before they replace anything, and
their source is saved with the cover. Recordings and covers are never uploaded,
and with lookup off the app works offline once the models are installed.

## Build

Requires Apple Silicon, macOS 14 or later, and Xcode 26 or later (for the Icon
Composer icon).

```sh
./scripts/build-moonshift.sh              # build/Moonshift.app, for this checkout
./scripts/build-moonshift.sh --notarize   # the same, notarized
./scripts/build-moonshift.sh --release    # self-contained, notarized, as a .dmg
.venv/bin/python -m pytest -q tests       # service tests
```

A local build is signed with the Developer ID certificate when it is in your
keychain, so macOS remembers the app's permissions across rebuilds; otherwise
it is signed for this Mac only. The signing identity can be overridden with
`MOONSHIFT_SIGN_IDENTITY`.

Notarizing uses the [`asc`](https://asccli.sh)
command line tool with an authentication profile for your team, and a Developer
ID certificate in your keychain. Set `MOONSHIFT_SIGN_IDENTITY` and
`MOONSHIFT_ASC_PROFILE` to your own; the script then signs, submits, staples
the ticket and runs a Gatekeeper check.

A checkout build is tied to its folder: the service, models and covers stay
there. A release build can run from anywhere: it carries the service, the setup
scripts, uv and the compiled music engine inside the app, and is written to
`build/release/`.

## Setup without the app

From a checkout, setup also builds the music engine, so it needs uv, CMake and
Apple's command line tools. The app's setup screen checks for them and offers
to install missing ones with Homebrew. (The release app ships that engine
prebuilt and needs none of these.)

```sh
./scripts/setup-moonshift.sh          # 4-bit music model, transcription, lookup helper
./scripts/setup-moonshift.sh q8       # 8-bit music model instead
./scripts/setup-moonshift.sh lookup   # only optional song identification
```

Everything is installed inside this folder, and finished downloads are reused.
Generation itself never downloads anything.

## What lives where

| Path | Purpose |
| --- | --- |
| `native/` | The SwiftUI app. `Model/` holds state and the service client, `Views/` the interface, `Resources/Moonshift.icon` the Icon Composer document |
| `studio/` | The local service: `server.py` owns the job queue, `worker.py` runs the music engine, `covers.py` transcribes, `song_lookup.py` handles metadata, lyrics and lookup |
| `scripts/` | Build and setup |
| `data/` | Your covers, imported songs and takes |
| `.models`, `.runtime`, `.venv`, `.covers-venv`, `.lookup-venv`, `.cache` | Model weights, the music engine, and Python environments |

The service listens only on `127.0.0.1:8766`, refuses requests from web pages,
and exits with the app.

## License

Moonshift — Copyright (C) 2026 Alan Bradburne

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; see [LICENSE](LICENSE) for the full terms.

The license covers Moonshift's own code. Downloaded models and runtimes keep
their own terms, which are non-commercial for the music and transcription
models; see the [third-party notices](THIRD_PARTY_NOTICES.md).
