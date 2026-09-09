#!/usr/bin/env python3
"""
Génère Resources/manifest.json à partir de Resources/audio/.

Le manifest est la source de vérité de l'app : quelles leçons existent, quelles
phrases les composent, dans quel ordre et avec quelle durée exacte (la durée pilote
la longueur de la pause de répétition en mode shadowing).

Structure d'une leçon dans la source Assimil :
  S00-TITLE      titre de la leçon
  S01..S19       phrases du dialogue (6 à 20 selon la leçon)
  T00-TRANSLATE  annonce de l'exercice de traduction
  T01..T05       phrases de l'exercice
  N<num>         annonce du numéro de leçon

Les 14 leçons de révision (7, 14, ... 98) n'ont pas d'exercice : c'est attendu.
Le préfixe ST des leçons 6/48/58 a déjà été normalisé en T par build-audio.sh.
"""

import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "Resources" / "audio"
OUT = ROOT / "Resources" / "manifest.json"

REVIEW_LESSONS = {7, 14, 21, 28, 35, 42, 49, 56, 63, 70, 77, 84, 91, 98}


def duration(path: Path) -> float:
    """Durée exacte en secondes, via ffprobe."""
    out = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return round(float(out), 3)


def build_lesson(lesson_dir: Path, durations: dict[Path, float]) -> dict:
    number = int(lesson_dir.name[1:])
    files = {f.stem: f for f in lesson_dir.glob("*.m4a")}

    def entry(stem: str, n: int | None = None) -> dict | None:
        f = files.get(stem)
        if f is None:
            return None
        e = {"file": f.name, "duration": durations[f]}
        if n is not None:
            e["n"] = n
        return e

    def numbered(prefix: str) -> list[dict]:
        items = []
        for stem in files:
            m = re.fullmatch(rf"{prefix}(\d+)", stem)
            if m and int(m.group(1)) > 0:
                items.append((int(m.group(1)), stem))
        return [entry(stem, n) for n, stem in sorted(items)]

    announcement = next(
        (entry(s) for s in files if re.fullmatch(r"N\d+", s)), None
    )

    return {
        "number": number,
        "isReview": number in REVIEW_LESSONS,
        "dir": lesson_dir.name,
        "announcement": announcement,
        "title": entry("S00-TITLE"),
        "dialogue": numbered("S"),
        "exerciseIntro": entry("T00-TRANSLATE"),
        "exercise": numbered("T"),
    }


def main() -> int:
    if not BUILD.is_dir():
        print("Resources/audio absent — lancer tools/build-audio.sh d'abord", file=sys.stderr)
        return 1

    lesson_dirs = sorted(d for d in BUILD.iterdir() if re.fullmatch(r"L\d{3}", d.name))
    all_files = [f for d in lesson_dirs for f in d.glob("*.m4a")]

    with ThreadPoolExecutor(max_workers=8) as pool:
        durations = dict(zip(all_files, pool.map(duration, all_files)))

    lessons = [build_lesson(d, durations) for d in lesson_dirs]

    manifest = {
        "version": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "lessonCount": len(lessons),
        "sentenceCount": sum(len(l["dialogue"]) + len(l["exercise"]) for l in lessons),
        "totalDuration": round(sum(durations.values()), 1),
        "lessons": lessons,
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

    # --- Contrôles ---------------------------------------------------------
    problems = []
    if len(lessons) != 100:
        problems.append(f"{len(lessons)} leçons au lieu de 100")

    for l in lessons:
        n = l["number"]
        if not l["dialogue"]:
            problems.append(f"L{n:03d} : aucune phrase de dialogue")
        if l["title"] is None:
            problems.append(f"L{n:03d} : titre manquant")
        if l["isReview"] and l["exercise"]:
            problems.append(f"L{n:03d} : leçon de révision avec exercice inattendu")
        if not l["isReview"] and not l["exercise"]:
            problems.append(f"L{n:03d} : exercice manquant (leçon non-révision)")

    # Les trois leçons dont la source nommait l'exercice « ST » : c'est
    # exactement le cas que la normalisation doit avoir rattrapé.
    for n in (6, 48, 58):
        got = len(lessons[n - 1]["exercise"])
        if got == 0:
            problems.append(f"L{n:03d} : exercice perdu — normalisation ST→T défaillante")

    print(f"{manifest['lessonCount']} leçons, {manifest['sentenceCount']} phrases, "
          f"{manifest['totalDuration'] / 3600:.2f} h")
    print(f"→ {OUT.relative_to(ROOT)}")

    if problems:
        print("\nAnomalies :", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print("Contrôles OK (révisions sans exercice, ST→T rattrapé sur 6/48/58)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
