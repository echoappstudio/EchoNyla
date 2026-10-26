#!/usr/bin/env python3
"""Checks Resources/AppIcon.icon/icon.json before the icon is compiled.

In an Icon Composer file the FIRST group and the FIRST layer are the FRONT-most (an earlier icon of
this app came out black because a full-size dark layer was listed first). Apple's compiler also allows
at most four groups. This fails if that order is wrong, there are more than four groups, a named image
is missing, or a file in Assets/ isn't used. It also checks the skin icons, the Apple Intelligence
loops and every bundled file-type icon exist.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ICON = Path(__file__).resolve().parent.parent / "Resources" / "AppIcon.icon"
FRONT_TO_BACK = ["glyph"]
# Verbyn's skins except Signature, whose icon is the app's own.
SKINS = ["sky", "green", "turquoise", "bordeaux", "wisteria"]
MAX_GROUPS = 4


def file_type_problems() -> list[str]:
    """Every icon named in Sources/EchoNylaCore/FileTypes.swift is in Resources/FileTypes, and nothing else is."""
    source = (ICON.parent.parent / "Sources" / "EchoNylaCore" / "FileTypes.swift").read_text()
    names = set(re.findall(r'\("([a-z_]+)", "', source))
    light = set(re.findall(r'"([a-z_]+)"', re.search(r"lightVersions: Set<String> = \[([^\]]*)\]", source).group(1)))
    wanted = {f"{name}.png" for name in names} | {f"{name}-light.png" for name in light} | {"LICENSE.txt"}
    folder = ICON.parent / "FileTypes"
    have = {path.name for path in folder.iterdir()}
    problems = [f"missing Resources/FileTypes/{name}" for name in sorted(wanted - have)]
    problems += [f"Resources/FileTypes/{name} is not used" for name in sorted(have - wanted)]
    if len(names) < 50:
        problems.append(f"only {len(names)} file-type icons found in FileTypes.swift")
    return problems


def main() -> int:
    data = json.loads((ICON / "icon.json").read_text())
    layers = [layer for group in data["groups"] for layer in group["layers"]]
    names = [layer["name"] for layer in layers]
    problems: list[str] = []
    if len(data["groups"]) > MAX_GROUPS:
        problems.append(f"{len(data['groups'])} groups; actool allows at most {MAX_GROUPS}")
    if names != FRONT_TO_BACK:
        problems.append(f"layers are {names}, expected front to back {FRONT_TO_BACK}")
    images = [layer["image-name"] for layer in layers]
    for image in images:
        if not (ICON / "Assets" / image).is_file():
            problems.append(f"missing Assets/{image}")
    for path in sorted((ICON / "Assets").iterdir()):
        if path.name not in images:
            problems.append(f"Assets/{path.name} is not used by icon.json")
    skin_icons = ICON.parent / "SkinIcons"
    for skin in SKINS:
        if not (skin_icons / f"icon-{skin}.png").is_file():
            problems.append(f"missing Resources/SkinIcons/icon-{skin}.png")
    for path in sorted(skin_icons.iterdir()):
        if path.stem.removeprefix("icon-") not in SKINS:
            problems.append(f"Resources/SkinIcons/{path.name} is not a skin")
    if not (ICON.parent / "IntelligenceLoops.png").is_file():
        problems.append("missing Resources/IntelligenceLoops.png")
    problems += file_type_problems()
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if not problems:
        print(f"icon.json: {' > '.join(names)} (front to back) in {len(data['groups'])} groups, all images present")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
