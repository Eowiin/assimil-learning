"""
Construit Resources/text/L0NN.json depuis content/asr/, pour les leçons dont le
livre n'est pas encore saisi.

Ce que ça donne : le texte espagnol des 100 leçons, apparié au bon numéro de phrase,
donc lisible à l'écran pendant l'écoute — la fonction principale de l'app. Aucun
scan nécessaire : l'audio étant découpé phrase par phrase, le numéro du fichier est
le numéro de la phrase.

Ce que ça ne donne pas : la traduction française, la prononciation figurée et les
notes, qui n'existent que dans le livre. Les fichiers portent donc `"source":
"audio"`, et l'app s'en sert pour ne pas proposer le thème inversé sur une leçon
sans traduction.

Mesure sur les 5 leçons relues depuis le livre : 99,5 % des mots corrects, 49
phrases sur 50 identiques mot pour mot. Ce qui diffère est la ponctuation — les
« ¡…! » d'Assimil ressortent surtout en points.

Un fichier déjà présent dans Resources/text/ n'est JAMAIS écrasé : le livre relu
fait foi, la transcription ne sert qu'à combler.

    python3 tools/asr-to-text.py            # toutes les leçons sans texte
    python3 tools/asr-to-text.py L006       # seulement celle-là
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASR = ROOT / "content" / "asr"
TEXT = ROOT / "Resources" / "text"
MANIFEST = ROOT / "Resources" / "manifest.json"

# Débit médian mesuré sur les 1613 clips (11 car/s) et silence de garde en tête et
# en queue de chaque fichier (~1 s). Un clip dont l'audio dure nettement plus que son
# texte ne l'explique cache soit des mots avalés — « A ver, » sur 5 secondes en leçon
# 87 — soit une diction lente légitime : un numéro épelé, un compte à rebours. Dans
# les deux cas ça mérite l'oreille, et 10 clips sur 1613 se réécoutent en cinq minutes.
CHARS_PER_SECOND = 11.0
LEAD_SILENCE = 1.0
UNEXPLAINED = 2.5

def suspicious(clip: dict) -> str | None:
    if not clip.get("es"):
        return "aucun texte reconnu"
    if clip.get("confidence", 1) < 0.5:
        return f"confiance {clip['confidence']:.2f}"
    expected = LEAD_SILENCE + len(clip["es"]) / CHARS_PER_SECOND
    gap = clip["duration"] - expected
    if gap > UNEXPLAINED:
        return f"{gap:.1f} s d'audio que le texte n'explique pas"
    return None

def build(asr: dict, lesson: dict) -> tuple[dict, list[str]]:
    problems = []

    def sentences(items: list[dict], expected: int, label: str) -> list[dict]:
        out = [{"n": r["n"], "es": r["es"]} for r in items
               if r.get("n") and r.get("es")]
        if len(out) != expected:
            problems.append(f"{label} : {len(out)} phrases transcrites "
                            f"pour {expected} fichiers audio")
        return out

    text = {
        "number": asr["number"],
        "source": "audio",
        "titleES": (asr.get("title") or {}).get("es") or None,
        "sentences": sentences(asr["dialogue"], len(lesson["dialogue"]), "dialogue"),
        "exercise": sentences(asr["exercise"], len(lesson["exercise"]), "exercice"),
    }
    return text, problems

def main() -> int:
    if not ASR.is_dir():
        print("content/asr absent — lancer tools/transcribe.swift d'abord",
              file=sys.stderr)
        return 1
    manifest = json.loads(MANIFEST.read_text())
    lessons = {l["number"]: l for l in manifest["lessons"]}

    names = sys.argv[1:] or [p.stem for p in sorted(ASR.glob("L*.json"))]
    written, kept, flagged = 0, [], []

    for name in names:
        src = ASR / f"{name}.json"
        if not src.exists():
            print(f"{name} : pas de transcription", file=sys.stderr)
            continue
        dest = TEXT / f"{name}.json"
        if dest.exists():
            existing = json.loads(dest.read_text())
            # Le livre relu fait foi. On ne l'écrase pas, même partiellement.
            if existing.get("source") != "audio":
                kept.append(name)
                continue

        asr = json.loads(src.read_text())
        text, problems = build(asr, lessons[asr["number"]])
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(text, ensure_ascii=False, indent=2) + "\n")
        written += 1
        doubts = [f"{c['file']} : {reason}"
                  for c in asr["dialogue"] + asr["exercise"]
                  if (reason := suspicious(c))]
        if problems or doubts:
            flagged.append((name, problems, doubts))

    print(f"{written} leçon(s) écrite(s) depuis l'audio")
    if kept:
        print(f"{len(kept)} leçon(s) laissée(s) intactes (texte du livre) : "
              f"{', '.join(kept)}")
    if flagged:
        print(f"\n{len(flagged)} leçon(s) à vérifier :")
        for name, problems, clips in flagged:
            for p in problems:
                print(f"  {name} — {p}")
            for c in clips[:4]:
                print(f"  {name} — {c}")
            if len(clips) > 4:
                print(f"  {name} — … et {len(clips) - 4} autre(s) clip(s)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
