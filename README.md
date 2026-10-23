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
   512 MB. Paste the lyrics, import or drop in a TXT, SRT, LRC, WebVTT or TTML
   file, or use *Find Online*. Subtitle timings and markup are removed on import.
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

- The Create screen's *Score* section shows the ABC notation a take follows.
  Edit it to change notes, chords or tempo; *Listen Now* writes it before a
  first take.
- A length is a ceiling. A shorter song ends sooner; a song longer than the
  limit is cut off, and the take says so.
- Every take uses a new random seed, so the same settings give a new performance.
- If rendering stops partway, the song already written is kept. *Resume
  Rendering* finishes it; *in Sections* is steadier on long songs.
- Memory and progress guards stop a job that would exhaust memory or has stalled.
- Singers are new voices shaped by a description. They do not clone a recording.

## Working with an agent

Moonshift has a built-in [Model Context Protocol](https://modelcontextprotocol.io)
server, so an AI agent can do what you can: read a cover's lyrics, style and
ABC score, change them, and render the result. Give it the score and ask it to
reharmonize the chorus, write a solo, or adapt the words to a new style; each
revision renders as a new take.

While Moonshift is open, the server answers at `http://127.0.0.1:8766/mcp`
to agents that send its token. Settings › Agents shows the command for Claude
Code with your token filled in, ready to copy:

```sh
claude mcp add --transport http moonshift http://127.0.0.1:8766/mcp --header "Authorization: Bearer <token>"
```

The token stays the same across launches; *New Token* in Settings replaces it
and disconnects agents added with the old one.

| Tool | What it does |
| --- | --- |
| `status` | Which models are installed, free memory, and what is rendering |
| `list_covers`, `get_cover` | Read covers, including the score and the audio paths of takes |
| `create_cover` | Start a cover from a recording on this Mac |
| `update_cover` | Change lyrics, style, singer, tempo, length, quality, or the score |
| `transcribe`, `create_take` | Listen to the recording; render the cover as it stands |
| `get_job`, `cancel_job`, `delete_take` | Follow, stop, and remove work |

A score an agent writes replaces the transcription until you choose *Use
Original Score* in the Score section of the Create screen, where you can also
read and edit the score yourself. Edits made by an agent appear in the app
as they happen, alongside any you are making. The server only answers on this
Mac, only to agents with the token, and refuses requests from web pages.

## Optional online lookup

Off until you turn it on. *Find Online* sends the song's title and artist to
LRCLIB. Naming an unrecognised recording sends a short audio fingerprint to
Shazam through ShazamIO, an unofficial interface that may change. Matches can
be wrong, so lyrics are shown for review before they replace anything, and
their source is saved with the cover. Recordings and covers are never uploaded,
and with lookup off the app works offline once the models are installed.

## Updates

The downloaded app checks GitHub for a newer release about once a day, sending
only its version. When there is one, it shows what changed and offers *Install
and Relaunch*; it installs only a build signed and notarized for Moonshift, and
never while a cover is being made. *Moonshift › Check for Updates…* checks at
any time, and Settings › General turns the daily check off. A build made from a
checkout does not update itself.

## Build

Requires Apple Silicon, macOS 14 or later, and Xcode 26 or later (for the Icon
Composer icon).

```sh
./scripts/build-moonshift.sh              # build/Moonshift.app, for this checkout
./scripts/build-moonshift.sh --notarize   # the same, notarized
./scripts/build-moonshift.sh --release    # self-contained, notarized, as a .dmg
./scripts/test-swift.sh                   # engine tests
uv run --no-project --with pytest python -m pytest -q tests   # transcription helper test
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

A checkout build is tied to its folder: models and covers stay there. A release
build can run from anywhere: it carries the transcription helper, the setup
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
| `native/` | The SwiftUI app. `Engine/` is the local engine: `Library` keeps covers and jobs, `JobRunner` and `MusicRender` run the models, `AgentTools` and `LoopbackServer` serve agents, `Lyrics` and `SongLookup` read lyrics and song details. `Model/` holds app state, `Views/` the interface, `Resources/Moonshift.icon` the Icon Composer document |
| `studio/` | The one model that runs in Python: `covers.py` transcribes a recording with SheetSage2. `recognize.py` is the optional Shazam helper |
| `scripts/` | Build and setup |
| `data/` | Your covers, imported songs and takes |
| `.models`, `.runtime`, `.covers-venv`, `.lookup-venv`, `.cache` | Model weights, the music engine, and Python environments |

The agent endpoint listens only on `127.0.0.1:8766`, needs the token kept in
`.runtime/agent-token`, refuses requests from web pages, and closes with the app.

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
