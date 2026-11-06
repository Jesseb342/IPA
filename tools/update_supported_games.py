#!/usr/bin/env python3
"""Build a compact, public catalog from ns2ios-shell's dm/games profiles."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

TITLE_ID_RE = re.compile(r"^[0-9A-Fa-f]{16}$")


def parse_game_tsv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values

    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "\t" not in line:
            continue
        key, value = line.split("\t", 1)
        values[key.strip()] = value.strip()
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    games_dir = args.upstream / "dm" / "games"
    if not games_dir.is_dir():
        raise SystemExit(f"Upstream profile directory not found: {games_dir}")

    upstream_commit = subprocess.check_output(
        ["git", "-C", str(args.upstream), "rev-parse", "HEAD"], text=True
    ).strip()

    entries: list[dict[str, object]] = []
    for folder in sorted(games_dir.iterdir(), key=lambda item: item.name.upper()):
        if not folder.is_dir() or not TITLE_ID_RE.fullmatch(folder.name):
            continue

        title_id = folder.name.upper()
        metadata = parse_game_tsv(folder / "game.tsv")
        has_game_tsv = (folder / "game.tsv").is_file()
        has_readme = (folder / "README.md").is_file()
        has_shader_map = (folder / "shader_map.tsv").is_file()
        has_pso_manifest = (folder / "pso_manifest.tsv").is_file()
        has_shader_facts = (folder / "shader_facts.tsv").is_file()
        has_shader_pairs = (folder / "shader_pairs.tsv").is_file()
        has_smoke = (folder / "smoke.tsv").is_file()

        # This describes profile artifacts only. It is deliberately not a
        # claim that the game has been tested or works on every iPhone.
        profile_status = (
            "profile_available"
            if has_game_tsv and has_shader_map
            else "profile_partial"
        )

        entries.append(
            {
                "titleId": title_id,
                "name": metadata.get("name") or title_id,
                "profileStatus": profile_status,
                "testStatus": "not_independently_verified",
                "files": {
                    "gameProfile": has_game_tsv,
                    "readme": has_readme,
                    "shaderMap": has_shader_map,
                    "shaderFacts": has_shader_facts,
                    "shaderPairs": has_shader_pairs,
                    "psoManifest": has_pso_manifest,
                    "smokeTestData": has_smoke,
                },
                "profileUrl": (
                    f"https://github.com/xinerqu/ns2ios-shell/tree/main/dm/games/{title_id}"
                ),
                "readmeUrl": (
                    f"https://github.com/xinerqu/ns2ios-shell/blob/main/dm/games/{title_id}/README.md"
                    if has_readme
                    else None
                ),
            }
        )

    if not entries:
        raise SystemExit("No valid game profile folders were found; refusing to publish an empty catalog.")

    document = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "source": {
            "repository": "xinerqu/ns2ios-shell",
            "branch": "main",
            "commit": upstream_commit,
            "profilesPath": "dm/games",
        },
        "count": len(entries),
        "statusDefinitions": {
            "profile_available": "A game.tsv and shader_map.tsv exist in the upstream profile folder. This is not a guarantee of successful operation on every device.",
            "profile_partial": "The upstream folder exists, but one or more core profile files are missing.",
            "not_independently_verified": "The upstream repository does not expose a consistent machine-readable test status for every game.",
        },
        "games": entries,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(entries)} game entries to {args.output}")
    print(f"Upstream commit: {upstream_commit}")


if __name__ == "__main__":
    main()
