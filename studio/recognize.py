"""Small opt-in ShazamIO helper; never loaded into a model worker."""
import asyncio
import json
import sys


async def identify(path):
    from shazamio import Shazam
    shazam = Shazam()
    result = await asyncio.wait_for(shazam.recognize(path), timeout=25)
    track = result.get("track") or {}
    return {"title": track.get("title", "")[:300], "artist": track.get("subtitle", "")[:300],
            "note": "Possible match from Shazam. Check the song and lyric version." if track else "No audio match found. Check the song name and search for lyrics."}


if __name__ == "__main__":
    print(json.dumps(asyncio.run(identify(sys.argv[1]))))
