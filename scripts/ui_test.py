#!/usr/bin/env python3
"""Smoke-tests a debug build of Clipboard through its real UI.

Runs against a temporary data folder, a private pasteboard and separate preferences, with global hotkeys
off, so the user's clipboard, history and shortcuts are untouched. Direct paste and detecting a real ⌘V need
Accessibility access, so they stay manual.

    scripts/ui_test.py [--screenshots DIR] [--app PATH] [--network]

--app tests an existing bundle built with -DDEBUG, for example an optimized one. --network also turns on
link previews, which contacts apple.com.
"""
import argparse
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
PASTEBOARD = "com.bunniesinc.clipboard.uitest"
RETURN, TAB, SPACE, DELETE, ESCAPE, LEFT, RIGHT = 36, 48, 49, 51, 53, 123, 124
CARD_PITCH, CARD_LEFT, CARD_Y = 242, 22, 190
SHELF_MARGINS, CODE_FILTER_FROM_RIGHT, BAR_Y, NEW_PINBOARD_X = 20, 122, 27, 454

parser = argparse.ArgumentParser()
parser.add_argument("--screenshots")
parser.add_argument("--app")
parser.add_argument("--network", action="store_true")
options = parser.parse_args()
app = pathlib.Path(options.app).resolve() if options.app else ROOT / "build/Clipboard.app"

work = pathlib.Path(tempfile.mkdtemp(prefix="paste-ui-test-"))
data = work / "data"
state_file = data / "test-state.json"
environment = {**os.environ, "PB_NAME": PASTEBOARD, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
failures = []


def check(label, condition, detail=""):
    print(f"{'ok  ' if condition else 'FAIL'} {label}{'' if condition else f'  ({detail})'}")
    if not condition:
        failures.append(label)


def tool(*arguments):
    return subprocess.run(
        [str(work / "testctl"), *map(str, arguments)], env=environment, text=True, capture_output=True, check=True
    ).stdout


def ctl(*command):
    return json.loads(tool("send", state_file, *command))


def copy(kind, *values, settle=0.55):
    tool(kind, *values)
    time.sleep(settle)


def key(code, *modifiers, character=""):
    parts = [code, *([character] if character else []), *modifiers]
    return ctl("key", *parts)


def database():
    return sqlite3.connect(f"file:{data}/history.sqlite?mode=ro", uri=True)


def clip_count():
    with database() as connection:
        return connection.execute("select count(*) from clips").fetchone()[0]


def screenshot(name, width_at_least=0, width_at_most=100_000):
    if options.screenshots:
        ctl("snapshot", width_at_least, width_at_most, pathlib.Path(options.screenshots) / f"{name}.png")


def card(index):
    return CARD_LEFT + index * CARD_PITCH + 114, CARD_Y


subprocess.run(
    ["swiftc", "-o", str(work / "testctl"), str(ROOT / "scripts/testctl.swift")], env=environment, check=True,
    capture_output=True,
)
if not options.app:
    subprocess.run([str(ROOT / "scripts/build-app.sh"), "--debug"], check=True, capture_output=True)
data.mkdir()
subprocess.run(["defaults", "delete", "com.bunniesinc.clipboard.uitest"], capture_output=True)
subprocess.run(
    ["defaults", "write", "com.bunniesinc.clipboard.uitest", "hasShownWelcome", "-bool", "true"], check=True
)
subprocess.run(
    ["defaults", "write", "com.bunniesinc.clipboard.uitest", "ignoredBundleIDs", "-array", "com.example.ignored"], check=True
)
if options.network:
    subprocess.run(["defaults", "write", "com.bunniesinc.clipboard.uitest", "linkPreviews", "-bool", "true"], check=True)

copy("text", "seed", settle=0)
subprocess.run(
    ["open", "-g", "-n", "--env", f"CLIPBOARD_DATA_DIR={data}", "--env", f"CLIPBOARD_TEST_PASTEBOARD={PASTEBOARD}",
     str(app)], check=True,
)
time.sleep(1.5)

try:
    print("\n# Capture")
    image_path = work / "receipt.png"
    tool("make-image", image_path, "Bakery receipt 4471")
    copy("image", image_path)
    copy("text", "The quarterly review moved to Thursday. Bring the forecast and the notes from planning.")
    copy("rich", "Formatted heading")
    copy("text", "https://www.apple.com/macos/")
    copy("text", "#3B82F6")
    copy("text", 'func greet(name: String) -> String {\n    return "Hello \\(name)"\n}')
    copy("files", image_path)
    copy("text", "Buy oat milk and sourdough")
    # Recognition runs at low priority, which macOS can hold back for a while when the screen is locked.
    deadline = time.time() + 45
    while True:
        with database() as connection:
            kinds = [row[0] for row in connection.execute("select kind from clips order by sort_at desc")]
            ocr = connection.execute("select ocr_text from clips where kind = 'image'").fetchone()[0]
        if ocr or time.time() > deadline:
            break
        time.sleep(0.5)
    check("every clip kind is classified", kinds == ["text", "file", "code", "color", "link", "text", "text", "image"], kinds)
    check("text inside images is recognised", ocr and "Bakery" in ocr, ocr)
    if options.network:
        time.sleep(6)
        with database() as connection:
            title = connection.execute("select link_title from clips where kind = 'link'").fetchone()[0]
        check("link previews fetch a title", bool(title), title)

    total = clip_count()
    copy("concealed", "hunter2-password")
    check("concealed copies are skipped", clip_count() == total)
    copy("text", "token ghp_abcdefghijklmnopqrstuvwxyz0123456789")
    check("secret-looking text is skipped", clip_count() == total)
    copy("from-app", "com.example.ignored", "From an ignored app")
    check("ignored apps are skipped", clip_count() == total)
    copy("text", "   ")
    check("whitespace is skipped", clip_count() == total)
    copy("text", "#3B82F6")
    check("copying a duplicate doesn't add a clip", clip_count() == total)
    ctl("pause", "on")
    copy("text", "Copied while paused")
    check("pausing stops capture", clip_count() == total)
    ctl("pause", "off")
    copy("text", "Buy oat milk and sourdough")

    print("\n# Shelf")
    state = ctl("state")
    check("starting in the background leaves focus alone", not state["appIsActive"])
    state = ctl("hotkey", "open")
    check("the shortcut handler opens the shelf", state["visible"] and state["windowFound"], state)
    check("the search field has focus", state["firstResponder"] == "NSTextView", state["firstResponder"])
    check("clips load newest first", state["clipCount"] == total and state["previews"][0].startswith("text: Buy oat"), state["previews"])
    screenshot("shelf", 1000)
    ctl("hover", 190, 210)
    screenshot("shelf-hover", 1000)
    ctl("hover")

    drag_image = work / "drag.png"
    ctl("drag-preview", drag_image)
    corners = subprocess.run(
        [str(work / "testctl"), "corner-alpha", str(drag_image)], text=True, capture_output=True
    ).stdout.split()
    check("the drag image has clean rounded corners", corners and all(float(value) == 0 for value in corners), corners)
    if options.screenshots and drag_image.exists():
        shutil.copy(drag_image, pathlib.Path(options.screenshots) / "drag-preview.png")

    print("\n# Keyboard")
    key(RIGHT)
    key(RIGHT)
    state = key(RIGHT)
    check("→ moves the selection", state["selectedIndex"] == 3, state["selectedIndex"])
    state = key(LEFT)
    check("← moves the selection", state["selectedIndex"] == 2, state["selectedIndex"])
    state = ctl("state")
    check("the row opens with the first card at its inset", abs(state["stripOffset"]) < 1, state["stripOffset"])
    state = key(RIGHT, "cmd")
    check("⌘→ jumps to the last clip", state["selectedIndex"] == total - 1, state["selectedIndex"])
    state = key(LEFT, "cmd")
    check("⌘← jumps to the first clip", state["selectedIndex"] == 0, state["selectedIndex"])

    state = ctl("flags", "cmd")
    check("holding ⌘ is noticed", state["commandHeld"])
    screenshot("shortcut-badges", 1000)
    state = ctl("flags", "none")
    check("releasing ⌘ is noticed", not state["commandHeld"])

    ctl("text", "bakery")
    time.sleep(0.2)
    state = ctl("state")
    check("typing searches, including image text", state["query"] == "bakery" and state["clipCount"] == 1 and state["previews"][0].startswith("image"), state["previews"])
    state = key(ESCAPE)
    time.sleep(0.2)
    state = ctl("state")
    check("⎋ clears the search first", state["visible"] and state["query"] == "" and state["clipCount"] == total, state["query"])

    state = key(SPACE)
    check("Space opens the preview", state["isPreviewing"])
    screenshot("preview", 806, 830)
    state = key(RIGHT)
    check("the preview follows the selection", state["isPreviewing"] and state["selectedIndex"] == 1)
    state = key(ESCAPE)
    check("⎋ closes the preview before the shelf", state["visible"] and not state["isPreviewing"])

    state = key(TAB)
    check("⇥ moves to Suggested", state["scope"] == "suggested", state["scope"])
    screenshot("suggested", 1000)
    state = key(TAB, "shift")
    check("⇧⇥ moves back", state["scope"] == "history", state["scope"])

    print("\n# Mouse")
    x, y = card(2)
    state = ctl("click", x, y)
    check("clicking a card selects it", state["selectedIndex"] == 2 and state["visible"], state["selectedIndex"])
    state = ctl("scroll", x, y, -120)
    check("a plain mouse wheel scrolls the row sideways", state["firstVisibleIndex"] >= 0)
    shelf_width = max(int(line.split()[1].split("x")[0]) for line in state["windows"]) - SHELF_MARGINS
    code_filter = shelf_width - CODE_FILTER_FROM_RIGHT
    state = ctl("click", code_filter, BAR_Y)
    check("clicking a filter applies it", state["kind"] == "code" and state["clipCount"] == 1, state["kind"])
    state = ctl("click", code_filter, BAR_Y)
    check("clicking it again clears it", state["kind"] == "all" and state["clipCount"] == total, state["kind"])

    print("\n# Pasting (Accessibility not granted, so clips land on the pasteboard)")
    trusted = state["trusted"]
    print(f"     Accessibility trusted: {trusted}")
    state = key(LEFT, "cmd")
    state = key(RIGHT)
    target = state["selectedPreview"]
    state = key(RETURN)
    check("↩ puts the clip on the pasteboard and closes", not state["visible"] and state["pasteboardText"] == target, state["pasteboardText"])
    check("restored clips carry the marker", "com.bunniesinc.clipboard.restored" in state["pasteboardTypes"], state["pasteboardTypes"])
    time.sleep(0.5)
    check("pasting doesn't capture the clip again", clip_count() == total)
    with database() as connection:
        pasted = connection.execute("select paste_count from clips order by sort_at desc limit 1").fetchone()[0]
    check("the pasted clip moves to the front and is counted", pasted == 1, pasted)
    screenshot("toast", 500, 540)

    state = ctl("show")
    check("the shelf reopens at the top with the pasted clip", state["selectedIndex"] == 0 and state["selectedPreview"] == target, state["selectedPreview"])
    index = next(i for i, preview in enumerate(state["previews"]) if preview.startswith("text: Formatted"))
    for _ in range(index):
        state = key(RIGHT)
    state = key(RETURN)
    check("↩ keeps formatting", "public.html" in state["pasteboardTypes"], state["pasteboardTypes"])
    state = ctl("show")
    state = key(RETURN, "shift")
    check("⇧↩ pastes plain text", "public.html" not in state["pasteboardTypes"] and state["pasteboardText"] == "Formatted heading", state["pasteboardTypes"])

    state = ctl("show")
    second = state["previews"][1]
    state = key(19, "cmd", character="2")
    check("⌘2 pastes the second clip", not state["visible"] and state["pasteboardText"].startswith(second.split(": ", 1)[1].rstrip()[:20]), state["pasteboardText"])

    state = ctl("show")
    x, y = card(1)
    expected = state["previews"][1].split(": ", 1)[1][:20]
    state = ctl("click", x, y, 2)
    check("double-clicking a card pastes it", not state["visible"] and state["pasteboardText"].startswith(expected), state["pasteboardText"])

    state = ctl("show")
    state = key(RIGHT)
    state = key(8, "cmd", character="c")
    check("⌘C copies without counting as a paste", not state["visible"] and state["pasteboardText"] == state["selectedPreview"], state["pasteboardText"])

    print("\n# Pinboards")
    state = ctl("show")
    state = ctl("click", NEW_PINBOARD_X, BAR_Y)
    check("+ starts a new pinboard", state["edit"].startswith("newPinboard"), state["edit"])
    check("the name field takes focus", state["firstResponder"] == "NSTextView", state["firstResponder"])
    screenshot("new-pinboard", 1000)
    ctl("text", "Work")
    state = key(RETURN)
    check("↩ creates the pinboard", state["boards"] == ["Work"] and state["edit"] == "none", state["boards"])
    check("the search field gets focus back", state["firstResponder"] == "NSTextView", state["firstResponder"])
    state = ctl("pin", "Work")
    state = key(TAB)
    state = key(TAB)
    check("⇥ reaches the pinboard and shows its clips", state["scope"].startswith("pinboard") and state["clipCount"] == 1, state["scope"])
    screenshot("pinboard", 1000)
    state = ctl("rename-board", "Work")
    ctl("text", "s")
    state = key(RETURN)
    check("renaming a pinboard works", state["boards"] == ["Works"], state["boards"])
    state = ctl("rename-clip")
    state = key(ESCAPE)
    check("⎋ cancels an edit without closing", state["edit"] == "none" and state["visible"], state["edit"])
    state = ctl("delete-board", "Works")
    check("deleting asks first", state["edit"].startswith("confirmDeletePinboard") and state["boards"] == ["Works"], state["edit"])
    screenshot("delete-pinboard", 1000)
    state = key(RETURN)
    time.sleep(0.2)
    state = ctl("state")
    check("deleting removes the pinboard, not its clips", state["boards"] == [] and state["scope"] == "history" and clip_count() == total, state["boards"])

    print("\n# Deleting")
    state = key(LEFT, "cmd")
    doomed = state["selectedPreview"]
    state = key(DELETE, "cmd")
    check("⌘⌫ deletes the selected clip", clip_count() == total - 1 and state["selectedPreview"] != doomed, state["selectedPreview"])
    state = key(ESCAPE)
    check("⎋ closes the shelf", not state["visible"])

    print("\n# Paste Stack")
    total = clip_count()
    state = ctl("hotkey", "stack")
    check("the shortcut handler starts a stack", state["stackActive"])
    screenshot("stack-empty", 330, 360)
    copy("text", "Stack item one")
    copy("text", "Stack item two")
    copy("text", "Stack item three")
    state = ctl("state")
    check("copies join the stack in order", state["stackItems"] == ["Stack item one", "Stack item two", "Stack item three"], state["stackItems"])
    check("the oldest item stays on the pasteboard", state["pasteboardText"] == "Stack item one", state["pasteboardText"])
    check("stack items are also in history", clip_count() == total + 3)
    screenshot("stack", 330, 360)
    state = ctl("stack-next")
    check("moving on loads the next item", state["pasteboardText"] == "Stack item two" and len(state["stackItems"]) == 2, state["stackItems"])
    ctl("stack-next")
    state = ctl("stack-next")
    check("the stack ends after its last item", not state["stackActive"], state["stackItems"])

    print("\n# Appearance and settings")
    ctl("appearance", "dark")
    ctl("show")
    time.sleep(0.3)
    screenshot("shelf-dark", 1000)
    ctl("hide")
    ctl("appearance", "light")
    state = ctl("settings")
    check("Settings opens", state["settingsVisible"], state)
    time.sleep(0.4)
    screenshot("settings-general", 790, 805)
    for page, name in [("shortcuts", "settings-shortcuts"), ("privacy", "settings-privacy"), ("aiTools", "settings-ai")]:
        ctl("settings-page", page)
        time.sleep(0.4)
        screenshot(name, 790, 805)
    ctl("settings-page", "general")
    ctl("appearance", "dark")
    time.sleep(0.4)
    screenshot("settings-dark", 790, 805)
    ctl("appearance", "light")
    state = ctl("settings-close")
    time.sleep(0.5)
    state = ctl("state")
    check("Settings closes", not state["settingsVisible"], state["settingsVisible"])

    print("\n# AI tools helper")
    helper = app / "Contents/MacOS/clipboard-mcp"
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "clipboard_search", "arguments": {"query": "bakery"}}},
    ]
    lines = subprocess.run(
        [str(helper)], input="".join(json.dumps(request) + "\n" for request in requests), text=True,
        capture_output=True, env={**os.environ, "CLIPBOARD_DATA_DIR": str(data)}, timeout=10,
    ).stdout.splitlines()
    responses = [json.loads(line) for line in lines]
    check("the helper answers every request except the notification", [r["id"] for r in responses] == [1, 2, 3], lines)
    check("it negotiates the protocol", responses[0]["result"]["protocolVersion"] == "2025-06-18")
    check("it refuses while sharing is off", responses[2]["result"].get("isError") is True, responses[2])
    with sqlite3.connect(data / "history.sqlite") as connection:
        connection.execute("insert into settings(key, value) values ('ai_access', 'everything')")
    lines = subprocess.run(
        [str(helper)], input=json.dumps(requests[3]) + "\n", text=True, capture_output=True,
        env={**os.environ, "CLIPBOARD_DATA_DIR": str(data)}, timeout=10,
    ).stdout.splitlines()
    found = json.loads(lines[0])["result"]["content"][0]["text"]
    check("once shared, it finds text inside images", '"kind":"image"' in found, found)

finally:
    subprocess.run(["pkill", "-f", str(app / "Contents/MacOS/Clipboard")])
    subprocess.run(["defaults", "delete", "com.bunniesinc.clipboard.uitest"], capture_output=True)
    shutil.rmtree(work, ignore_errors=True)

print(f"\n{'All checks passed' if not failures else str(len(failures)) + ' failed: ' + ', '.join(failures)}")
sys.exit(1 if failures else 0)
