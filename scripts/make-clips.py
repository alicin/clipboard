#!/usr/bin/env python3
"""Cuts the README's autoplaying clips out of the demo movie.

    scripts/make-demo.sh MOVIE.mp4 | tee RENDER.log
    scripts/make-clips.py MOVIE.mp4 RENDER.log [name ...]

Each clip runs between two of the movie's captions, which are read from the render log so the cuts survive a
reshoot. The clips are animated WebP, which autoplays in a README like a GIF does, without a GIF's banding or size.
Needs ffmpeg and img2webp (Homebrew's webp).
"""
import concurrent.futures
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "demo-assets/readme"
MOVIE_FPS = 60
CLIP_FPS = 20
QUALITY = 85
LOOP_FADE = 0.5
FULL_WIDTH = 960
HALF_WIDTH = 720

# name, width, start caption, seconds after it, end caption, seconds after it, and optionally a crop for wide shots
# that are too small to read at half width: the fraction to keep, and where it sits across and down the frame.
CLIPS = [
    ("open", FULL_WIDTH, "Copy anything, in any app", 0.5, "Every clip, at a glance", 2.0),
    ("tour", FULL_WIDTH, "Links", -0.3, "Secrets stay hidden", -0.2),
    ("paste", FULL_WIDTH, "↩ pastes where you left off", -0.3, "Formatting comes along", -0.3),
    ("search", HALF_WIDTH, "Just start typing", -0.2, "Filter by kind", -0.3),
    ("filters", HALF_WIDTH, "Filter by kind", -0.2, "Space for a closer look", -0.3, (0.72, 1.0, 1.0)),
    ("preview", HALF_WIDTH, "Space for a closer look", -0.2, "Pinboards keep what matters", -0.3),
    ("numbers", HALF_WIDTH, "Hold ⌘ for instant picks", -0.2, "↩ pastes where you left off", -0.3, (0.72, 0.25, 1.0)),
    ("pinboards", FULL_WIDTH, "Pinboards keep what matters", -0.2, "Suggested knows your habits", -0.3),
    ("suggested", HALF_WIDTH, "Suggested knows your habits", -0.2, "Name it, or lose it", -0.3),
    ("stack", HALF_WIDTH, "Paste Stack: copy many, paste in order", -0.2, "Settings that get out of your way", -0.3),
    ("secrets", HALF_WIDTH, "Secrets stay hidden", -0.3, "Cards respond to your pointer", -0.3),
    ("privacy", HALF_WIDTH, "Your clipboard stays yours", -0.2, "Your clipboard stays yours", 5.2),
    ("ai", FULL_WIDTH, "Your AI tools can search it too", -0.2, "At home in the dark", -0.3),
    ("settings", HALF_WIDTH, "Turn on direct paste once", -0.2, "Your clipboard stays yours", -0.3),
    ("dark", HALF_WIDTH, "At home in the dark", -0.2, "At home in the dark", 5.0),
]


def caption_times(log):
    times = {}
    for line in pathlib.Path(log).read_text().splitlines():
        match = re.match(r"demo: caption (\d+) (.+)", line)
        if match:
            times[match.group(2)] = int(match.group(1)) / MOVIE_FPS
    return times


def cut(movie, times, clip):
    name, width, start_caption, start_offset, end_caption, end_offset, *crop = clip
    start = times[start_caption] + start_offset
    end = times[end_caption] + end_offset
    duration = end - start
    framing = ""
    if crop:
        keep, across, down = crop[0]
        framing = f"crop=iw*{keep}:ih*{keep}:(iw-ow)*{across}:(ih-oh)*{down},"
    work = pathlib.Path(tempfile.mkdtemp(prefix=f"clip-{name}-"))
    try:
        # The ending fades back into the opening, so the loop has no visible jump.
        graph = (
            f"[0:v]split[a][b];"
            f"[a]trim=start={LOOP_FADE},setpts=PTS-STARTPTS[body];"
            f"[b]trim=end={LOOP_FADE},setpts=PTS-STARTPTS[head];"
            f"[body][head]xfade=transition=fade:duration={LOOP_FADE}:offset={duration - 2 * LOOP_FADE},"
            f"{framing}fps={CLIP_FPS},scale={width}:-2:flags=lanczos"
        )
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-ss", str(start), "-t", str(duration), "-i", movie,
             "-filter_complex", graph, str(work / "%05d.png")],
            check=True,
        )
        frames = sorted(work.glob("*.png"))
        target = OUTPUT / f"{name}.webp"
        subprocess.run(
            ["img2webp", "-loop", "0", "-lossy", "-q", str(QUALITY), "-m", "6", "-sharp_yuv", "-d", str(round(1000 / CLIP_FPS)),
             *map(str, frames), "-o", str(target)],
            check=True, capture_output=True,
        )
        return name, duration, target.stat().st_size
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    movie, log, *names = sys.argv[1:]
    times = caption_times(log)
    chosen = [clip for clip in CLIPS if not names or clip[0] in names]
    OUTPUT.mkdir(parents=True, exist_ok=True)
    total = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for name, duration, size in pool.map(lambda clip: cut(movie, times, clip), chosen):
            total += size
            print(f"{name:10} {duration:5.1f}s {size / 1_000_000:6.2f} MB")
    print(f"{'total':10}        {total / 1_000_000:6.2f} MB")


main()
